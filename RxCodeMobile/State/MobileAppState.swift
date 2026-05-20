import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI
import UIKit
import os.log

/// A pending request to open a specific thread, set when the user taps an APNs
/// notification. `RootView` observes this and pushes the chat detail page.
/// `requestID` makes every tap a distinct value, so `onChange` still fires when
/// the user re-taps a notification for a thread they already navigated away from.
struct MobileDeepLink: Equatable {
    let sessionID: String
    let projectID: UUID?
    let requestID = UUID()
}

struct PairedDesktop: Codable, Identifiable, Equatable, Hashable {
    var pubkeyHex: String
    var displayName: String
    var pairedAt: Date
    var lastSeen: Date?

    var id: String { pubkeyHex }
}

/// Single source of truth for the mobile app. Owns the `SyncClient`, the
/// decoded projects/sessions/messages mirrored from the paired desktop, and
/// the pairing flow.
@MainActor
final class MobileAppState: ObservableObject {
    enum PairingStatus: Equatable {
        case idle
        case inProgress
        case failed(String)
    }

    @Published var isPaired: Bool = false
    @Published var pairedDesktopName: String = ""
    @Published var pairedDesktopPubkey: String = ""
    @Published var pairedDesktops: [PairedDesktop] = []
    @Published var connectionState: RelayClient.ConnectionState = .disconnected
    @Published var relayURL: URL
    @Published var pairingStatus: PairingStatus = .idle

    @Published var projects: [Project] = []
    @Published var sessions: [SessionSummary] = []
    @Published var branchBriefings: [MobileBranchBriefing] = []
    @Published var threadSummaries: [MobileThreadSummary] = []
    @Published var desktopSettings: MobileSettingsSnapshot?
    /// Agent rate-limit usage mirrored from the paired desktop. `nil` until the
    /// first snapshot arrives, or when paired with a desktop that predates
    /// usage sync.
    @Published var desktopUsage: MobileUsageSnapshot?
    /// Desktop CPU/memory/thermal load mirrored from the paired desktop. `nil`
    /// until the first snapshot arrives, or when paired with a desktop that
    /// predates computer-status sync.
    @Published var desktopHostMetrics: HostMetricsSnapshot?
    /// Desktop HTTP proxy used by the in-app browser to load localhost URLs
    /// from the paired Mac instead of from the iPad.
    @Published var desktopWebProxy: MobileWebProxyInfo?
    /// Current git branch per project, mirrored from the desktop's snapshot.
    @Published var projectBranches: [UUID: String] = [:]
    /// Local branch list per project, mirrored from the desktop's snapshot.
    @Published var availableBranchesByProject: [UUID: [String]] = [:]
    /// Desktop-owned run profiles per project, mirrored into the mobile app.
    @Published var runProfilesByProject: [UUID: [RunProfile]] = [:]
    /// Recent and active run tasks mirrored from the desktop.
    @Published var runTasks: [MobileRunTaskSnapshot] = []
    @Published var inFlightRunProfileRequests: Set<UUID> = []
    @Published var lastRunProfileError: String?

    // MARK: - Remote desktop config: Skills

    /// Marketplace catalog mirrored from the desktop, with per-plugin install
    /// state. Populated lazily when the skill screen opens.
    @Published var skillCatalog: [MobileSkillPlugin] = []
    @Published var skillCatalogLoading = false
    @Published var skillCatalogError: String?
    @Published var skillSources: [MobileSkillSource] = []
    /// Plugin ids with an in-flight install/uninstall request — drives per-row
    /// spinners.
    @Published var inFlightSkillMutations: Set<String> = []
    @Published var inFlightSkillSourceMutations: Set<String> = []
    @Published var lastSkillError: String?
    /// The latest catalog request id, so a stale reply is discarded.
    private var pendingSkillCatalogRequestID: UUID?
    private var skillSourceMutationKeys: [UUID: String] = [:]

    // MARK: - Remote desktop config: ACP agent clients

    @Published var acpRegistryAgents: [MobileACPRegistryAgent] = []
    @Published var acpInstalledClients: [MobileACPClient] = []
    @Published var acpRegistryLoading = false
    @Published var acpRegistryError: String?
    /// Registry-agent ids or installed-client ids with an in-flight mutation.
    @Published var inFlightACPMutations: Set<String> = []
    @Published var lastACPError: String?
    private var pendingACPRegistryRequestID: UUID?
    /// Maps an ACP mutation request id to the identity key tracked in
    /// `inFlightACPMutations`, so the result clears the right row.
    private var acpMutationKeys: [UUID: String] = [:]

    // MARK: - Remote desktop config: MCP servers

    @Published var mcpServers: [MobileMCPServer] = []
    @Published var mcpConfigLoading = false
    @Published var mcpConfigError: String?
    /// Server names with an in-flight add/remove/toggle request.
    @Published var inFlightMCPMutations: Set<String> = []
    @Published var lastMCPError: String?
    private var pendingMCPConfigRequestID: UUID?
    /// IDs of branch operations awaiting a `BranchOpResultPayload`. Used so the
    /// UI can render a spinner on the chip while the desktop runs git.
    @Published var inFlightBranchOps: Set<UUID> = []
    /// Last branch op error message, surfaced once and cleared by the UI.
    @Published var lastBranchOpError: String?
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    /// Sessions the desktop currently reports as producing reasoning/thinking
    /// tokens. Drives the "Thinking…" label in the streaming indicator.
    @Published var thinkingSessions: Set<String> = []
    /// Sessions known to have messages older than the window currently held in
    /// `messagesBySession`. Drives the scroll-up "load more" affordance.
    @Published var sessionsWithMoreMessages: Set<String> = []
    /// Sessions with an in-flight `load_more_messages` request.
    @Published var loadingMoreSessions: Set<String> = []
    /// Maps an outstanding load-more request ID to its session, so a late
    /// `more_messages` reply lands on the right thread.
    private var pendingLoadMoreRequests: [UUID: String] = [:]
    /// Messages per history page — must match the desktop's expectation.
    private static let messagePageSize = 30
    @Published var activeSessionID: String?
    /// Set when the user taps an APNs notification; `RootView` observes this and
    /// navigates to the thread's chat detail page, then clears it.
    @Published var pendingDeepLink: MobileDeepLink?
    @Published var pendingPermission: PermissionRequestPayload?
    /// Every `AskUserQuestion` call the desktop currently has awaiting an
    /// answer, across all sessions. Mirrored from the desktop's queue; the chat
    /// view filters it by session to drive the question banner and sheet.
    @Published var pendingQuestions: [PendingQuestionPayload] = []

    @Published var searchQuery: String = ""
    @Published var searchProjectIDs: [UUID] = []
    @Published var searchThreadHits: [SearchHit] = []
    @Published var isSearching: Bool = false
    private var pendingSearchID: UUID?
    private var searchDebounceTask: Task<Void, Never>?

    /// Backing data for the thread "View Changes" sheet — thread file edits and
    /// uncommitted git changes for one thread. Nil until first loaded; carries
    /// its own `sessionID` so a stale result for another thread is ignored.
    @Published var threadChanges: ThreadChangesResultPayload?
    @Published var isLoadingThreadChanges: Bool = false
    private var pendingThreadChangesID: UUID?

    @Published var remoteFolderRoot: RemoteFolderNode?
    @Published var remoteFolderIsLoading = false
    @Published var remoteFolderError: String?
    @Published var remoteProjectCreateInFlight = false
    @Published var remoteProjectCreateError: String?
    @Published var lastCreatedProjectID: UUID?
    private var pendingFolderTreeRequestID: UUID?
    private var pendingCreateProjectRequestID: UUID?

    private var identity: DeviceIdentity
    private var client: SyncClient
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileAppState")
    private var eventTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var apnsTokenHex: String?
    private var apnsEnvironment: String?
    private var clientStarted = false

    static let pairingTimeoutSeconds: UInt64 = 25
    private static let pairedDesktopsKey = "mobileSync.pairedDesktops"
    private static let activeDesktopPubkeyKey = "mobileSync.activeDesktopPubkey"
    private static let legacyDesktopPubkeyKey = "mobileSync.desktopPubkey"
    private static let legacyDesktopNameKey = "mobileSync.desktopName"
    private static let mobilePubkeyKey = "mobileSync.mobilePubkey"

    init() {
        let stored = UserDefaults.standard.string(forKey: "mobileSync.relayURL")
        let initial = URL(string: stored ?? Self.defaultRelayURLString)
            ?? URL(string: Self.defaultRelayURLString)!
        self.relayURL = initial
        do {
            // Shared access group lets the Notification Service Extension
            // read the private key for decrypting APNs alerts. The bare group
            // suffix is matched against the (already-expanded) entitlement —
            // never pass the literal `$(AppIdentifierPrefix)…` here, that's a
            // build-time substitution and is meaningless at runtime.
            self.identity = try DeviceIdentity.loadOrCreate(
                accessGroup: Self.keychainAccessGroup
            )
        } catch {
            Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileAppState")
                .error("[MobileIdentity] load failed accessGroup=\(Self.keychainAccessGroup, privacy: .public): \(error.localizedDescription, privacy: .public)")
            fatalError("Failed to load mobile device identity: \(error)")
        }
        self.client = SyncClient(identity: identity, relayURL: initial)
        logger.info("[MobileIdentity] loaded publicKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public) accessGroup=\(Self.keychainAccessGroup, privacy: .public)")
        loadPairedDesktops()
    }

    /// Bare suffix as declared (post-`$(AppIdentifierPrefix)`) in
    /// `RxCodeMobile.entitlements` and the NSE entitlements file.
    static let keychainAccessGroupSuffix = "app.rxlab.rxcodemobile.shared"

    /// Fully-qualified access group resolved at runtime (e.g.
    /// `T7GYB573Y6.app.rxlab.rxcodemobile.shared`). iOS requires the prefixed
    /// form when calling `SecItem*`.
    static var keychainAccessGroup: String {
        DeviceIdentity.resolveAccessGroup(suffix: keychainAccessGroupSuffix)
    }

    static var defaultRelayURLString: String {
        #if DEBUG
        return "ws://localhost:8787/ws"
        #else
        return "wss://relay.rxlab.app/ws"
        #endif
    }

    var localPublicKeyHex: String { identity.publicKeyHex }

    var activePairedDesktop: PairedDesktop? {
        pairedDesktops.first { $0.pubkeyHex == pairedDesktopPubkey }
    }

    func start() {
        Task { @MainActor in
            await startClient()
        }
    }

    /// Drive the relay connection from the app lifecycle. iOS suspends the
    /// process shortly after backgrounding, which kills the WebSocket on an
    /// unpredictable schedule; disconnecting deterministically keeps the
    /// relay's registration table in sync with reality and gives a clean,
    /// single re-register on the next foreground.
    func handleScenePhase(_ phase: ScenePhase) {
        guard clientStarted else { return }
        switch phase {
        case .background:
            logger.info("[Lifecycle] entering background — disconnecting relay")
            Task { await client.stop() }
        case .active:
            logger.info("[Lifecycle] entering foreground — reconnecting relay")
            Task { await client.start() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func startClient() async {
        clientStarted = true
        for desktop in pairedDesktops {
            try? await client.addPeer(desktop.pubkeyHex)
        }
        let events = await client.events()
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in events {
                self.handle(event)
            }
        }
        await client.start()
        // Re-request snapshot on every (re)start so we don't show stale state.
        if isPaired {
            await requestSnapshot(reason: "client_start")
            await reportAPNsTokenIfPending()
        }
    }

    // MARK: - Pairing

    func pair(with token: PairingToken, displayName: String) async {
        guard !token.isExpired,
              let desktopKey = token.desktopPublicKey else {
            failPairing("Invalid or expired pairing code.")
            return
        }
        pairingStatus = .inProgress
        let desktopHex = token.desktopPubkeyHex
        logger.info("pairing with relayURL=\(token.relayURL, privacy: .public)")
        // Persist the relay URL we just learned from the QR.
        if let url = URL(string: token.relayURL) {
            await updateRelayForPairingIfNeeded(url)
        } else {
            logger.error("pairing token has invalid relayURL=\(token.relayURL, privacy: .public)")
        }
        if !clientStarted {
            await startClient()
        }
        try? await client.addPeer(desktopHex)
        guard await waitForRelayConnection() else {
            logger.error("pairing relay connection timed out relay=\(self.relayURL.absoluteString, privacy: .public)")
            failPairing("Couldn't connect to the relay from the QR code. Check the relay address and try again.")
            return
        }
        let req = PairRequestPayload(
            mobilePubkeyHex: identity.publicKeyHex,
            displayName: displayName,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
        do {
            logger.info("sending pair request via relay=\(self.relayURL.absoluteString, privacy: .public)")
            try await client.send(.pairRequest(req), toHex: desktopHex)
        } catch {
            logger.error("pair request send failed: \(error.localizedDescription, privacy: .public)")
            failPairing("Couldn't reach the relay. Check your network and try again.")
            return
        }
        _ = desktopKey  // silence unused
        startPairingTimeout()
    }

    func pair(from url: URL, displayName: String) async {
        do {
            let token = try PairingToken.parse(url.absoluteString)
            await pair(with: token, displayName: displayName)
        } catch {
            logger.error("pairing deeplink parse failed: \(error.localizedDescription, privacy: .public)")
            failPairing("Unrecognized pairing link. Generate a new QR code on your Mac.")
        }
    }

    private func updateRelayForPairingIfNeeded(_ url: URL) async {
        UserDefaults.standard.set(url.absoluteString, forKey: "mobileSync.relayURL")
        guard url != relayURL else {
            logger.info("pairing relay already configured as \(url.absoluteString, privacy: .public)")
            return
        }

        logger.info("switching pairing relay to \(url.absoluteString, privacy: .public)")
        let oldClient = client
        eventTask?.cancel()
        eventTask = nil
        client = SyncClient(identity: identity, relayURL: url)
        relayURL = url
        connectionState = .disconnected
        await oldClient.stop()
        await startClient()
    }

    private func waitForRelayConnection(timeoutSeconds: Double = 8) async -> Bool {
        logger.info("waiting for relay connection state=\(String(describing: self.connectionState), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public)")
        if connectionState == .connected { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if connectionState == .connected { return true }
        }
        return false
    }

    func cancelPairing() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingStatus = .idle
    }

    func dismissPairingError() {
        if case .failed = pairingStatus { pairingStatus = .idle }
    }

    private func startPairingTimeout() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            let seconds = Self.pairingTimeoutSeconds
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.pairingStatus == .inProgress else { return }
                self.failPairing(
                    "Your Mac didn't respond. Make sure RxCode is open and connected, then try again."
                )
            }
        }
    }

    // MARK: - User intents

    func sendUserMessage(_ text: String, sessionID: String) async {
        guard isPaired else { return }
        let payload = UserMessagePayload(sessionID: sessionID, text: text)
        try? await client.send(.userMessage(payload), toHex: pairedDesktopPubkey)
    }

    func cancelStream(sessionID: String) async {
        guard isPaired else { return }
        let payload = CancelStreamPayload(sessionID: sessionID)
        try? await client.send(.cancelStream(payload), toHex: pairedDesktopPubkey)
    }

    func removeQueuedMessage(sessionID: String, queuedID: UUID) async {
        guard isPaired else { return }
        let payload = RemoveQueuedMessagePayload(sessionID: sessionID, queuedMessageID: queuedID)
        try? await client.send(.removeQueuedMessage(payload), toHex: pairedDesktopPubkey)
    }

    /// True iff the desktop reports the given session as actively streaming.
    func isSessionStreaming(_ sessionID: String) -> Bool {
        sessions.first(where: { $0.id == sessionID })?.isStreaming ?? false
    }

    /// True iff the desktop reports the given session as currently producing
    /// reasoning/thinking tokens.
    func isSessionThinking(_ sessionID: String) -> Bool {
        thinkingSessions.contains(sessionID)
    }

    /// Whether the given session has messages older than the loaded window.
    func hasMoreMessages(sessionID: String) -> Bool {
        sessionsWithMoreMessages.contains(sessionID)
    }

    /// Whether an older page is currently being fetched for the given session.
    func isLoadingMoreMessages(sessionID: String) -> Bool {
        loadingMoreSessions.contains(sessionID)
    }

    /// Mirror of the desktop's per-session queue, surfaced via `SessionSummary`.
    func queuedMessages(sessionID: String) -> [QueuedUserMessage] {
        sessions.first(where: { $0.id == sessionID })?.queuedMessages ?? []
    }

    /// Ask the desktop to create a new thread. The per-thread agent config
    /// (model, permission mode, plan mode) travels in the request so the thread
    /// is created with exactly the chosen config — fixing the bug where a
    /// non-default model was dropped in favor of the project default. ACP client
    /// and effort have no mobile picker, so they ride along from the last synced
    /// desktop settings.
    func requestNewSession(
        projectID: UUID,
        initialText: String? = nil,
        agentProvider: AgentProvider? = nil,
        model: String? = nil,
        permissionMode: PermissionMode? = nil,
        planMode: Bool = false
    ) async {
        guard isPaired else { return }
        let payload = NewSessionRequestPayload(
            projectID: projectID,
            initialText: initialText,
            selectedAgentProvider: agentProvider,
            selectedModel: model,
            selectedACPClientId: desktopSettings?.selectedACPClientId,
            selectedEffort: desktopSettings?.selectedEffort,
            permissionMode: permissionMode,
            planMode: planMode
        )
        try? await client.send(.newSessionRequest(payload), toHex: pairedDesktopPubkey)
    }

    func requestRemoteFolder(path: String? = nil) async {
        guard isPaired else { return }
        let request = FolderTreeRequestPayload(path: path, depth: 1)
        pendingFolderTreeRequestID = request.clientRequestID
        remoteFolderIsLoading = true
        remoteFolderError = nil
        do {
            try await client.send(.folderTreeRequest(request), toHex: pairedDesktopPubkey)
        } catch {
            pendingFolderTreeRequestID = nil
            remoteFolderIsLoading = false
            remoteFolderError = error.localizedDescription
        }
    }

    func createProjectFromRemoteFolder(path: String) async {
        guard isPaired else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let request = CreateProjectRequestPayload(path: trimmed)
        pendingCreateProjectRequestID = request.clientRequestID
        remoteProjectCreateInFlight = true
        remoteProjectCreateError = nil
        do {
            try await client.send(.createProjectRequest(request), toHex: pairedDesktopPubkey)
        } catch {
            pendingCreateProjectRequestID = nil
            remoteProjectCreateInFlight = false
            remoteProjectCreateError = error.localizedDescription
        }
    }

    // MARK: - Plan mode

    /// Plan cards for a session, derived live from the synced messages using the
    /// shared `PlanLogic` — the same `ExitPlanMode` detection the desktop chat
    /// uses. Superseded plans (re-emitted within the same turn) are dropped so
    /// only actionable cards surface.
    func pendingPlans(sessionID: String) -> [PendingPlan] {
        let messages = messagesBySession[sessionID] ?? []
        var plans: [PendingPlan] = []
        for message in messages {
            for block in message.blocks {
                guard let toolCall = block.toolCall,
                      PlanLogic.isExitPlanMode(toolCall) else { continue }
                if PlanLogic.isSupersededExitPlanMode(
                    toolCall: toolCall, in: message, allMessages: messages
                ) { continue }
                let markdown = PlanLogic.renderMarkdown(for: toolCall, in: message) ?? ""
                let decided = PlanLogic.isPlanDecided(toolCall)
                plans.append(PendingPlan(
                    toolCallId: toolCall.id,
                    markdown: markdown,
                    isStreaming: !decided && markdown.isEmpty && message.isStreaming,
                    isDecided: decided,
                    decisionSummary: decided ? toolCall.result : nil
                ))
            }
        }
        return plans
    }

    /// Send the user's plan decision to the desktop, which resolves the CLI
    /// `ExitPlanMode` hook via `respondToPlanDecision`. No optimistic mutation —
    /// the desktop broadcasts the updated `toolCall.result` back through the
    /// normal session-update sync, so the banner and chat reconcile from that.
    func respondToPlanDecision(
        toolUseID: String,
        sessionID: String,
        action: PlanDecisionAction
    ) async {
        guard isPaired else { return }
        let payload = PlanDecisionPayload(
            toolUseID: toolUseID,
            sessionID: sessionID,
            decision: action
        )
        try? await client.send(.planDecision(payload), toHex: pairedDesktopPubkey)
    }

    // MARK: - Thread lifecycle actions

    /// Rename a thread. The local title is updated optimistically; the desktop
    /// confirms via the next snapshot / session update.
    func renameThread(sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replaceSession(sessionID: sessionID) { current in
            SessionSummary(
                id: current.id,
                projectId: current.projectId,
                title: trimmed,
                updatedAt: current.updatedAt,
                isPinned: current.isPinned,
                isArchived: current.isArchived,
                isStreaming: current.isStreaming,
                attention: current.attention,
                progress: current.progress,
                queuedMessages: current.queuedMessages
            )
        }
        await sendThreadAction(sessionID: sessionID, action: .rename, newTitle: trimmed)
    }

    /// Archive a thread. Optimistically flips `isArchived` so the row drops out
    /// of the active list right away.
    func archiveThread(sessionID: String) async {
        replaceSession(sessionID: sessionID) { current in
            SessionSummary(
                id: current.id,
                projectId: current.projectId,
                title: current.title,
                updatedAt: current.updatedAt,
                isPinned: current.isPinned,
                isArchived: true,
                isStreaming: current.isStreaming,
                attention: current.attention,
                progress: current.progress,
                queuedMessages: current.queuedMessages
            )
        }
        await sendThreadAction(sessionID: sessionID, action: .archive)
    }

    /// Delete a thread. Optimistically drops it from local state.
    func deleteThread(sessionID: String) async {
        sessions.removeAll { $0.id == sessionID }
        messagesBySession.removeValue(forKey: sessionID)
        sessionsWithMoreMessages.remove(sessionID)
        loadingMoreSessions.remove(sessionID)
        if activeSessionID == sessionID { activeSessionID = nil }
        await sendThreadAction(sessionID: sessionID, action: .delete)
    }

    private func replaceSession(sessionID: String, _ transform: (SessionSummary) -> SessionSummary) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index] = transform(sessions[index])
    }

    private func sendThreadAction(
        sessionID: String,
        action: ThreadActionRequestPayload.Action,
        newTitle: String? = nil
    ) async {
        guard isPaired else {
            logger.error("[ThreadAction] not paired — dropping action=\(action.rawValue, privacy: .public)")
            return
        }
        let payload = ThreadActionRequestPayload(
            sessionID: sessionID,
            action: action,
            newTitle: newTitle
        )
        do {
            try await client.send(.threadActionRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[ThreadAction] sent action=\(action.rawValue, privacy: .public) thread=\(sessionID, privacy: .public)")
        } catch {
            logger.error("[ThreadAction] send failed action=\(action.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tell the desktop to switch the project to an existing local branch.
    /// Returns immediately; the eventual snapshot broadcast carries the new
    /// `currentBranch` and any error surfaces via `lastBranchOpError`.
    func switchProjectBranch(projectID: UUID, branch: String) async {
        guard isPaired else { return }
        let request = BranchOpRequestPayload(
            projectID: projectID,
            operation: .switchExisting,
            branch: branch
        )
        inFlightBranchOps.insert(request.clientRequestID)
        try? await client.send(.branchOpRequest(request), toHex: pairedDesktopPubkey)
    }

    /// Tell the desktop to create a new branch + worktree off the current
    /// branch. The desktop parks the worktree against the project so the next
    /// new-thread request for this project spawns into it.
    func createProjectBranch(projectID: UUID, branch: String) async {
        guard isPaired else { return }
        let request = BranchOpRequestPayload(
            projectID: projectID,
            operation: .createNew,
            branch: branch
        )
        inFlightBranchOps.insert(request.clientRequestID)
        try? await client.send(.branchOpRequest(request), toHex: pairedDesktopPubkey)
    }

    func clearBranchOpError() {
        lastBranchOpError = nil
    }

    func subscribe(to sessionID: String?) async {
        activeSessionID = sessionID
        guard isPaired else { return }
        let payload = SubscribeSessionPayload(sessionID: sessionID)
        try? await client.send(.subscribeSession(payload), toHex: pairedDesktopPubkey)
    }

    // MARK: - Message paging

    /// Ask the desktop for the page of messages immediately older than the
    /// oldest one currently loaded for `sessionID`. No-op when there's nothing
    /// older, a request is already in flight, or the thread has no messages yet.
    /// Returns `true` when a request was dispatched — callers can then expect
    /// `isLoadingMoreMessages(sessionID:)` to flip back to `false` once it
    /// settles.
    @discardableResult
    func loadMoreMessages(sessionID: String) async -> Bool {
        guard isPaired,
              sessionsWithMoreMessages.contains(sessionID),
              !loadingMoreSessions.contains(sessionID),
              let oldest = messagesBySession[sessionID]?.first
        else { return false }

        let requestID = UUID()
        loadingMoreSessions.insert(sessionID)
        pendingLoadMoreRequests[requestID] = sessionID

        let payload = LoadMoreMessagesRequestPayload(
            clientRequestID: requestID,
            sessionID: sessionID,
            beforeMessageID: oldest.id,
            limit: Self.messagePageSize
        )
        do {
            try await client.send(.loadMoreMessages(payload), toHex: pairedDesktopPubkey)
        } catch {
            loadingMoreSessions.remove(sessionID)
            pendingLoadMoreRequests.removeValue(forKey: requestID)
        }
        return true
    }

    /// Fold an older page returned by the desktop into the local window.
    private func applyMoreMessages(_ page: MoreMessagesPayload) {
        guard let sessionID = pendingLoadMoreRequests.removeValue(forKey: page.clientRequestID)
        else { return }
        loadingMoreSessions.remove(sessionID)

        if !page.messages.isEmpty {
            var current = messagesBySession[sessionID] ?? []
            let known = Set(current.map(\.id))
            let fresh = page.messages.filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                current.insert(contentsOf: fresh, at: 0)
                messagesBySession[sessionID] = current
            }
        }

        if page.hasMore {
            sessionsWithMoreMessages.insert(sessionID)
        } else {
            sessionsWithMoreMessages.remove(sessionID)
        }
    }

    /// Requests the change overview (thread file edits + uncommitted git
    /// changes) for `sessionID` from the desktop. The reply lands in
    /// `threadChanges` via the `threadChangesResult` payload.
    func requestThreadChanges(sessionID: String) async {
        guard isPaired else { return }
        let requestID = UUID()
        pendingThreadChangesID = requestID
        isLoadingThreadChanges = true
        let payload = ThreadChangesRequestPayload(clientRequestID: requestID, sessionID: sessionID)
        do {
            try await client.send(.threadChangesRequest(payload), toHex: pairedDesktopPubkey)
        } catch {
            if pendingThreadChangesID == requestID {
                pendingThreadChangesID = nil
                isLoadingThreadChanges = false
            }
        }
    }

    func respondToPermission(allow: Bool, denyReason: String? = nil) async {
        guard let pending = pendingPermission else { return }
        let payload = PermissionResponsePayload(
            requestID: pending.requestID,
            allow: allow,
            denyReason: denyReason
        )
        try? await client.send(.permissionResponse(payload), toHex: pairedDesktopPubkey)
        pendingPermission = nil
    }

    // MARK: - AskUserQuestion

    /// Pending `AskUserQuestion` calls for one session, in the order the desktop
    /// queued them.
    func pendingQuestions(sessionID: String) -> [PendingQuestionPayload] {
        pendingQuestions.filter { $0.sessionID == sessionID }
    }

    /// Submit the user's answers for one `AskUserQuestion` call to the desktop.
    /// The request is dropped from the local queue optimistically; the desktop
    /// re-broadcasts the authoritative queue once it resolves the tool call.
    func answerQuestion(toolUseID: String, answers: [Int: AskUserQuestion.Answer]) async {
        guard isPaired else { return }
        let entries: [QuestionAnswerEntry] = answers.map { index, answer in
            switch answer {
            case .single(let value):
                return QuestionAnswerEntry(questionIndex: index, values: [value], multiSelect: false)
            case .multi(let values):
                return QuestionAnswerEntry(questionIndex: index, values: values, multiSelect: true)
            }
        }
        let payload = QuestionAnswerPayload(toolUseID: toolUseID, answers: entries)
        try? await client.send(.questionAnswer(payload), toHex: pairedDesktopPubkey)
        pendingQuestions.removeAll { $0.toolUseID == toolUseID }
    }

    /// Skip one `AskUserQuestion` call. An empty answer set tells the desktop to
    /// resolve the tool call as denied.
    func skipQuestion(toolUseID: String) async {
        guard isPaired else { return }
        let payload = QuestionAnswerPayload(toolUseID: toolUseID, answers: [])
        try? await client.send(.questionAnswer(payload), toHex: pairedDesktopPubkey)
        pendingQuestions.removeAll { $0.toolUseID == toolUseID }
    }

    func updateDesktopSettings(_ update: MobileSettingsUpdatePayload) async {
        guard isPaired else { return }
        applySettingsUpdateLocally(update)
        try? await client.send(.settingsUpdate(update), toHex: pairedDesktopPubkey)
    }

    func refreshSnapshot() async {
        await requestSnapshot()
    }

    func runProfiles(for projectID: UUID) -> [RunProfile] {
        runProfilesByProject[projectID] ?? []
    }

    func runTasks(for projectID: UUID) -> [MobileRunTaskSnapshot] {
        runTasks.filter { $0.projectId == projectID }
    }

    func runningTask(projectID: UUID, profileID: UUID) -> MobileRunTaskSnapshot? {
        runTasks.first {
            $0.projectId == projectID && $0.profileId == profileID && $0.isRunning
        }
    }

    func saveRunProfile(_ profile: RunProfile, projectID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] save dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public) profile=\(profile.id.uuidString, privacy: .public)")
            return
        }
        var next = runProfilesByProject[projectID] ?? []
        if let idx = next.firstIndex(where: { $0.id == profile.id }) {
            next[idx] = profile
        } else {
            next.append(profile)
        }
        runProfilesByProject[projectID] = next

        let payload = RunProfileMutationRequestPayload(
            projectID: projectID,
            operation: .upsert,
            profile: profile,
            profileID: profile.id
        )
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileMutationRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent save request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profile.id.uuidString, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = "Failed to send run profile update: \(error.localizedDescription)"
            logger.error("[RunProfiles] save send failed id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profile.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteRunProfile(projectID: UUID, profileID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] delete dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
            return
        }
        runProfilesByProject[projectID]?.removeAll { $0.id == profileID }
        let payload = RunProfileMutationRequestPayload(
            projectID: projectID,
            operation: .delete,
            profileID: profileID
        )
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileMutationRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent delete request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = "Failed to send run profile delete: \(error.localizedDescription)"
            logger.error("[RunProfiles] delete send failed id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func runProfile(projectID: UUID, profileID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] run dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
            return
        }
        let payload = RunProfileRunRequestPayload(projectID: projectID, profileID: profileID)
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileRunRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent run request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = "Failed to send run request: \(error.localizedDescription)"
            logger.error("[RunProfiles] run send failed id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopRunTask(_ task: MobileRunTaskSnapshot) async {
        guard isPaired else {
            logger.error("[RunProfiles] stop dropped because mobile is not paired task=\(task.taskId.uuidString, privacy: .public)")
            return
        }
        let payload = RunProfileStopRequestPayload(
            taskID: task.taskId,
            projectID: task.projectId,
            profileID: task.profileId
        )
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileStopRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent stop request id=\(payload.clientRequestID.uuidString, privacy: .public) task=\(task.taskId.uuidString, privacy: .public) project=\(task.projectId.uuidString, privacy: .public) profile=\(task.profileId.uuidString, privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = "Failed to send stop request: \(error.localizedDescription)"
            logger.error("[RunProfiles] stop send failed id=\(payload.clientRequestID.uuidString, privacy: .public) task=\(task.taskId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Update the search query and dispatch a debounced search request to the
    /// paired desktop. Empty queries clear results without hitting the network.
    /// Stale requests are discarded by `clientRequestID`.
    func updateSearchQuery(_ query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounceTask?.cancel()
        guard !trimmed.isEmpty else {
            pendingSearchID = nil
            isSearching = false
            searchProjectIDs = []
            searchThreadHits = []
            return
        }
        guard isPaired else {
            isSearching = false
            searchProjectIDs = []
            searchThreadHits = []
            return
        }
        let id = UUID()
        pendingSearchID = id
        isSearching = true
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingSearchID == id else { return }
            let payload = SearchRequestPayload(clientRequestID: id, query: trimmed, limit: 25)
            try? await self.client.send(.searchRequest(payload), toHex: self.pairedDesktopPubkey)
        }
    }

    func reportAPNsToken(hex: String, environment: String) {
        logger.info("[APNs] received token from app delegate tokenPrefix=\(String(hex.prefix(12)), privacy: .public) environment=\(environment, privacy: .public)")
        apnsTokenHex = hex
        apnsEnvironment = environment
        Task { await reportAPNsTokenIfPending() }
    }

    // MARK: - Live Activity & widget

    /// Forward a Live Activity push token (a push-to-start token, a per-activity
    /// update token, or both) to every paired desktop so it can drive the job
    /// Live Activity over APNs. Called by `MobileLiveActivityCoordinator`.
    func sendLiveActivityToken(_ payload: LiveActivityTokenPayload) async {
        guard !pairedDesktops.isEmpty else { return }
        for desktop in pairedDesktops {
            do {
                try await client.send(.liveActivityToken(payload), toHex: desktop.pubkeyHex)
                logger.info("[LiveActivity] token reported startToken=\(payload.pushToStartTokenHex != nil, privacy: .public) activityToken=\(payload.activityTokenHex != nil, privacy: .public) startedLocally=\(payload.activityStartedLocally == true, privacy: .public) dismissed=\(payload.activityDismissed == true, privacy: .public) session=\(payload.sessionID ?? "<nil>", privacy: .public) desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public)")
            } catch {
                logger.error("[LiveActivity] token report failed desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Recompute the home-screen widget snapshot from the current mirrored
    /// state and persist it into the shared App Group container. Cheap to call
    /// often — `RxCodeWidgetStore` reloads WidgetKit timelines on a real change.
    func refreshWidgetData() {
        let jobCount = sessions.filter { $0.isStreaming }.count
        let snapshot = RxCodeWidgetData(
            jobCount: jobCount,
            ccUsagePercent: desktopUsage?.claudeCode?.fiveHourPercent,
            codexUsagePercent: desktopUsage?.codex?.fiveHourPercent,
            updatedAt: Date().timeIntervalSince1970
        )
        RxCodeWidgetStore.save(snapshot)
    }

    /// Routes a tapped APNs notification to its thread. Called by `AppDelegate`'s
    /// `didReceive` handler; `RootView` observes `pendingDeepLink` and navigates.
    func openThreadFromNotification(sessionID: String, projectID: UUID?) {
        logger.info("[APNs] notification tap -> open thread sessionID=\(sessionID, privacy: .public) projectID=\(projectID?.uuidString ?? "<nil>", privacy: .public)")
        pendingDeepLink = MobileDeepLink(sessionID: sessionID, projectID: projectID)
    }

    func switchPairedDesktop(_ desktop: PairedDesktop) async {
        guard pairedDesktops.contains(where: { $0.pubkeyHex == desktop.pubkeyHex }) else { return }
        guard desktop.pubkeyHex != pairedDesktopPubkey else { return }
        clearDesktopMirror()
        setActiveDesktop(pubkeyHex: desktop.pubkeyHex)
        savePairedDesktops()
        try? await client.addPeer(desktop.pubkeyHex)
        await requestSnapshot()
        await reportAPNsTokenIfPending()
    }

    func removePairedDesktop(_ desktop: PairedDesktop) async {
        let wasActive = desktop.pubkeyHex == pairedDesktopPubkey
        try? await client.send(.unpair(UnpairPayload(reason: "mobile")), toHex: desktop.pubkeyHex)
        pairedDesktops.removeAll { $0.pubkeyHex == desktop.pubkeyHex }
        await client.removePeer(desktop.pubkeyHex)

        if wasActive {
            clearDesktopMirror()
            setActiveDesktop(pubkeyHex: pairedDesktops.first?.pubkeyHex)
        } else {
            setActiveDesktop(pubkeyHex: pairedDesktopPubkey)
        }
        savePairedDesktops()

        if wasActive, isPaired {
            await requestSnapshot()
            await reportAPNsTokenIfPending()
        }
    }

    func unpair() async {
        guard let desktop = activePairedDesktop else { return }
        await removePairedDesktop(desktop)
    }

    private func clearDesktopMirror() {
        projects = []
        sessions = []
        branchBriefings = []
        threadSummaries = []
        desktopSettings = nil
        desktopUsage = nil
        desktopHostMetrics = nil
        desktopWebProxy = nil
        projectBranches = [:]
        availableBranchesByProject = [:]
        runProfilesByProject = [:]
        runTasks = []
        inFlightRunProfileRequests = []
        lastRunProfileError = nil
        inFlightBranchOps = []
        lastBranchOpError = nil
        messagesBySession = [:]
        thinkingSessions = []
        sessionsWithMoreMessages = []
        loadingMoreSessions = []
        pendingLoadMoreRequests = [:]
        remoteFolderRoot = nil
        remoteFolderIsLoading = false
        remoteFolderError = nil
        remoteProjectCreateInFlight = false
        remoteProjectCreateError = nil
        pendingFolderTreeRequestID = nil
        pendingCreateProjectRequestID = nil
        lastCreatedProjectID = nil
        activeSessionID = nil
        pendingPermission = nil
        pendingQuestions = []
        skillCatalog = []
        skillCatalogLoading = false
        skillCatalogError = nil
        skillSources = []
        inFlightSkillMutations = []
        inFlightSkillSourceMutations = []
        lastSkillError = nil
        pendingSkillCatalogRequestID = nil
        skillSourceMutationKeys = [:]
        acpRegistryAgents = []
        acpInstalledClients = []
        acpRegistryLoading = false
        acpRegistryError = nil
        inFlightACPMutations = []
        lastACPError = nil
        pendingACPRegistryRequestID = nil
        acpMutationKeys = [:]
        mcpServers = []
        mcpConfigLoading = false
        mcpConfigError = nil
        inFlightMCPMutations = []
        lastMCPError = nil
        pendingMCPConfigRequestID = nil
    }

    // MARK: - Remote desktop configuration

    /// Timeout after which a stuck remote config request is cleared and an
    /// error surfaced. ACP installs download a binary, so they get longer.
    private static let remoteConfigTimeout: Duration = .seconds(20)
    private static let acpInstallTimeout: Duration = .seconds(90)

    /// Runs `perform` on the main actor after `timeout`. Callers use it to
    /// expire a request that never received a reply (relay dropped, etc.).
    private func scheduleTimeout(
        _ timeout: Duration,
        perform: @escaping (MobileAppState) -> Void
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self else { return }
            perform(self)
        }
    }

    // Skills

    func requestSkillCatalog(forceRefresh: Bool = false) async {
        guard isPaired else {
            skillCatalogError = "Connect a Mac to browse skills."
            return
        }
        let payload = SkillCatalogRequestPayload(forceRefresh: forceRefresh)
        pendingSkillCatalogRequestID = payload.clientRequestID
        skillCatalogLoading = true
        skillCatalogError = nil
        do {
            try await client.send(.skillCatalogRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.pendingSkillCatalogRequestID == payload.clientRequestID {
                    s.pendingSkillCatalogRequestID = nil
                    s.skillCatalogLoading = false
                    s.skillCatalogError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            skillCatalogLoading = false
            skillCatalogError = "Failed to request skills: \(error.localizedDescription)"
            if pendingSkillCatalogRequestID == payload.clientRequestID {
                pendingSkillCatalogRequestID = nil
            }
        }
    }

    func installSkill(_ pluginID: String) async {
        await mutateSkill(pluginID, operation: .install)
    }

    func uninstallSkill(_ pluginID: String) async {
        await mutateSkill(pluginID, operation: .uninstall)
    }

    func addSkillGitSource(url: String, ref: String?) async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            lastSkillError = "Enter a GitHub repository URL."
            return
        }
        let trimmedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "add:\(trimmedURL)"
        await mutateSkillSource(
            key: key,
            operation: .add,
            gitURL: trimmedURL,
            ref: trimmedRef?.isEmpty == false ? trimmedRef : nil
        )
    }

    func removeSkillGitSource(_ sourceID: String) async {
        await mutateSkillSource(key: sourceID, operation: .remove, sourceID: sourceID)
    }

    private func mutateSkill(_ pluginID: String, operation: SkillMutationRequestPayload.Operation) async {
        guard isPaired else {
            lastSkillError = "Connect a Mac first."
            return
        }
        guard !inFlightSkillMutations.contains(pluginID) else { return }
        let payload = SkillMutationRequestPayload(operation: operation, pluginID: pluginID)
        inFlightSkillMutations.insert(pluginID)
        lastSkillError = nil
        do {
            try await client.send(.skillMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.inFlightSkillMutations.remove(pluginID) != nil {
                    s.lastSkillError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            inFlightSkillMutations.remove(pluginID)
            lastSkillError = "Failed to send request: \(error.localizedDescription)"
        }
    }

    private func mutateSkillSource(
        key: String,
        operation: SkillSourceMutationRequestPayload.Operation,
        sourceID: String? = nil,
        gitURL: String? = nil,
        ref: String? = nil
    ) async {
        guard isPaired else {
            lastSkillError = "Connect a Mac first."
            return
        }
        guard !inFlightSkillSourceMutations.contains(key) else { return }
        let payload = SkillSourceMutationRequestPayload(
            operation: operation,
            sourceID: sourceID,
            gitURL: gitURL,
            ref: ref
        )
        inFlightSkillSourceMutations.insert(key)
        skillSourceMutationKeys[payload.clientRequestID] = key
        lastSkillError = nil
        do {
            try await client.send(.skillSourceMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if let key = s.skillSourceMutationKeys.removeValue(forKey: payload.clientRequestID) {
                    s.inFlightSkillSourceMutations.remove(key)
                    s.lastSkillError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            skillSourceMutationKeys.removeValue(forKey: payload.clientRequestID)
            inFlightSkillSourceMutations.remove(key)
            lastSkillError = "Failed to send request: \(error.localizedDescription)"
        }
    }

    // ACP agent clients

    func requestACPRegistry(forceRefresh: Bool = false) async {
        guard isPaired else {
            acpRegistryError = "Connect a Mac to manage agents."
            return
        }
        let payload = ACPRegistryRequestPayload(forceRefresh: forceRefresh)
        pendingACPRegistryRequestID = payload.clientRequestID
        acpRegistryLoading = true
        acpRegistryError = nil
        do {
            try await client.send(.acpRegistryRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.pendingACPRegistryRequestID == payload.clientRequestID {
                    s.pendingACPRegistryRequestID = nil
                    s.acpRegistryLoading = false
                    s.acpRegistryError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            acpRegistryLoading = false
            acpRegistryError = "Failed to request agents: \(error.localizedDescription)"
            if pendingACPRegistryRequestID == payload.clientRequestID {
                pendingACPRegistryRequestID = nil
            }
        }
    }

    func installACPAgent(_ registryAgentID: String) async {
        await mutateACP(operation: .install, key: registryAgentID, registryAgentID: registryAgentID)
    }

    func uninstallACPClient(_ clientID: String) async {
        await mutateACP(operation: .uninstall, key: clientID, clientID: clientID)
    }

    func setACPClientEnabled(_ clientID: String, enabled: Bool) async {
        await mutateACP(operation: .setEnabled, key: clientID, clientID: clientID, enabled: enabled)
    }

    private func mutateACP(
        operation: ACPMutationRequestPayload.Operation,
        key: String,
        registryAgentID: String? = nil,
        clientID: String? = nil,
        enabled: Bool? = nil
    ) async {
        guard isPaired else {
            lastACPError = "Connect a Mac first."
            return
        }
        guard !inFlightACPMutations.contains(key) else { return }
        let payload = ACPMutationRequestPayload(
            operation: operation,
            registryAgentID: registryAgentID,
            clientID: clientID,
            enabled: enabled
        )
        inFlightACPMutations.insert(key)
        acpMutationKeys[payload.clientRequestID] = key
        lastACPError = nil
        let timeout = operation == .install ? Self.acpInstallTimeout : Self.remoteConfigTimeout
        do {
            try await client.send(.acpMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(timeout) { s in
                if s.acpMutationKeys.removeValue(forKey: payload.clientRequestID) != nil {
                    s.inFlightACPMutations.remove(key)
                    s.lastACPError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            acpMutationKeys.removeValue(forKey: payload.clientRequestID)
            inFlightACPMutations.remove(key)
            lastACPError = "Failed to send request: \(error.localizedDescription)"
        }
    }

    // MCP servers

    func requestMCPConfig() async {
        guard isPaired else {
            mcpConfigError = "Connect a Mac to manage MCP servers."
            return
        }
        let payload = MCPConfigRequestPayload()
        pendingMCPConfigRequestID = payload.clientRequestID
        mcpConfigLoading = true
        mcpConfigError = nil
        do {
            try await client.send(.mcpConfigRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.pendingMCPConfigRequestID == payload.clientRequestID {
                    s.pendingMCPConfigRequestID = nil
                    s.mcpConfigLoading = false
                    s.mcpConfigError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            mcpConfigLoading = false
            mcpConfigError = "Failed to request MCP servers: \(error.localizedDescription)"
            if pendingMCPConfigRequestID == payload.clientRequestID {
                pendingMCPConfigRequestID = nil
            }
        }
    }

    func addMCPServer(_ server: MobileMCPServer) async {
        await mutateMCP(operation: .add, serverName: server.name, server: server)
    }

    func removeMCPServer(_ serverName: String) async {
        await mutateMCP(operation: .remove, serverName: serverName)
    }

    func setMCPServerEnabled(_ serverName: String, enabled: Bool) async {
        await mutateMCP(operation: .setEnabled, serverName: serverName, enabled: enabled)
    }

    private func mutateMCP(
        operation: MCPMutationRequestPayload.Operation,
        serverName: String,
        server: MobileMCPServer? = nil,
        enabled: Bool? = nil
    ) async {
        guard isPaired else {
            lastMCPError = "Connect a Mac first."
            return
        }
        guard !inFlightMCPMutations.contains(serverName) else { return }
        let payload = MCPMutationRequestPayload(
            operation: operation,
            serverName: serverName,
            server: server,
            enabled: enabled
        )
        inFlightMCPMutations.insert(serverName)
        lastMCPError = nil
        do {
            try await client.send(.mcpMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.inFlightMCPMutations.remove(serverName) != nil {
                    s.lastMCPError = "Request timed out. Check your Mac and try again."
                }
            }
        } catch {
            inFlightMCPMutations.remove(serverName)
            lastMCPError = "Failed to send request: \(error.localizedDescription)"
        }
    }

    // MARK: - Inbound events

    private func handle(_ event: RelayClient.Event) {
        switch event {
        case .stateChanged(let state):
            logger.info("[Relay] connection state changed: \(String(describing: state), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public)")
            let previous = connectionState
            connectionState = state
            triggerConnectionFeedback(from: previous, to: state)
            if case .connected = state, isPaired {
                Task { await self.requestSnapshot(reason: "relay_connected") }
            }
        case .deliveryFailed(let toHex):
            logger.warning("[Relay] delivery failed to desktopKey=\(String(toHex.prefix(12)), privacy: .public)")
        case .inbound(let inbound):
            handleInbound(inbound)
        }
    }

    private func handleInbound(_ inbound: RelayClient.Inbound) {
        switch inbound.payload {
        case .pairAck(let ack):
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            if ack.accepted {
                upsertPairedDesktop(
                    PairedDesktop(
                        pubkeyHex: inbound.fromHex,
                        displayName: ack.desktopName,
                        pairedAt: .now,
                        lastSeen: .now
                    )
                )
                setActiveDesktop(pubkeyHex: inbound.fromHex)
                pairingStatus = .idle
                logger.info("[Pairing] accepted desktop=\(ack.desktopName, privacy: .public) desktopKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
                MobileHaptics.connected()
                savePairedDesktops()
                Task {
                    await self.requestSnapshot()
                    await self.reportAPNsTokenIfPending()
                }
            } else {
                failPairing("Your Mac declined the pairing request.")
            }
        case .unpair:
            guard let desktop = pairedDesktops.first(where: { $0.pubkeyHex == inbound.fromHex }) else { return }
            Task { await self.removePairedDesktopAfterRemoteUnpair(desktop) }
        case .snapshot(let snap):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "snapshot") else { return }
            let profileProjectCount = snap.runProfiles?.count ?? 0
            let profileTotal = snap.runProfiles?.reduce(0) { $0 + $1.profiles.count } ?? 0
            logger.info("[MobileSync] applying snapshot projects=\(snap.projects.count, privacy: .public) sessions=\(snap.sessions.count, privacy: .public) runProfileProjects=\(profileProjectCount, privacy: .public) runProfileTotal=\(profileTotal, privacy: .public) runTasks=\(snap.runTasks?.count ?? 0, privacy: .public) from desktopKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            projects = snap.projects
            sessions = snap.sessions
            branchBriefings = snap.branchBriefings ?? []
            threadSummaries = snap.threadSummaries ?? []
            desktopSettings = snap.settings
            desktopUsage = snap.usage
            desktopHostMetrics = snap.hostMetrics
            desktopWebProxy = snap.webProxy
            if let webProxy = snap.webProxy {
                logger.info("[WebBrowserSync] snapshot web proxy host=\(webProxy.host, privacy: .public) port=\(webProxy.port, privacy: .public)")
            } else {
                logger.warning("[WebBrowserSync] snapshot missing web proxy info")
            }
            if let runProfiles = snap.runProfiles {
                runProfilesByProject = Dictionary(
                    uniqueKeysWithValues: runProfiles.map { ($0.projectId, $0.profiles) }
                )
            }
            if let tasks = snap.runTasks {
                runTasks = tasks.sorted { $0.startedAt > $1.startedAt }
            }
            if let branches = snap.projectBranches {
                projectBranches = Dictionary(uniqueKeysWithValues: branches.map { ($0.projectId, $0.currentBranch) })
                availableBranchesByProject = Dictionary(
                    uniqueKeysWithValues: branches.compactMap { info -> (UUID, [String])? in
                        guard let list = info.availableBranches else { return nil }
                        return (info.projectId, list)
                    }
                )
            }
            if let active = snap.activeSessionID {
                if let messages = snap.activeSessionMessages {
                    // The snapshot carries only the most recent page; replacing
                    // the window resets paging to that page.
                    messagesBySession[active] = messages
                    if snap.activeSessionHasMore == true {
                        sessionsWithMoreMessages.insert(active)
                    } else {
                        sessionsWithMoreMessages.remove(active)
                    }
                    loadingMoreSessions.remove(active)
                } else if messagesBySession[active] == nil {
                    messagesBySession[active] = []
                }
                activeSessionID = active
            }
            refreshWidgetData()
        case .moreMessages(let page):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "more_messages") else { return }
            applyMoreMessages(page)
        case .sessionUpdate(let update):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "session_update") else { return }
            applySessionUpdate(update)
            refreshWidgetData()
        case .permissionRequest(let req):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "permission_request") else { return }
            pendingPermission = req
            MobileHaptics.attentionNeeded()
        case .questionQueue(let queue):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "question_queue") else { return }
            let grew = queue.questions.count > pendingQuestions.count
            pendingQuestions = queue.questions
            if grew { MobileHaptics.attentionNeeded() }
        case .notification:
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "notification") else { return }
            // Foreground notifications arriving over WS — iOS won't show a
            // banner automatically; UI surfaces these in a toast/badge.
            break
        case .searchResults(let results):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "search_results") else { return }
            guard let pending = pendingSearchID, results.clientRequestID == pending else { return }
            searchProjectIDs = results.projectIDs
            searchThreadHits = results.threadHits
            isSearching = false
        case .threadChangesResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "thread_changes_result") else { return }
            guard let pending = pendingThreadChangesID, result.clientRequestID == pending else { return }
            pendingThreadChangesID = nil
            isLoadingThreadChanges = false
            threadChanges = result
        case .branchOpResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "branch_op_result") else { return }
            inFlightBranchOps.remove(result.clientRequestID)
            if !result.ok {
                lastBranchOpError = result.errorMessage ?? "Branch operation failed."
            }
        case .folderTreeResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "folder_tree_result") else { return }
            guard pendingFolderTreeRequestID == result.clientRequestID else { return }
            pendingFolderTreeRequestID = nil
            remoteFolderIsLoading = false
            if result.ok, let root = result.root {
                remoteFolderRoot = root
                remoteFolderError = nil
            } else {
                remoteFolderError = result.errorMessage ?? "Failed to load folders."
            }
        case .createProjectResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "create_project_result") else { return }
            guard pendingCreateProjectRequestID == result.clientRequestID else { return }
            pendingCreateProjectRequestID = nil
            remoteProjectCreateInFlight = false
            if result.ok, let project = result.project {
                if !projects.contains(where: { $0.id == project.id }) {
                    projects.append(project)
                }
                lastCreatedProjectID = project.id
                remoteProjectCreateError = nil
                Task { await self.requestSnapshot() }
            } else {
                remoteProjectCreateError = result.errorMessage ?? "Failed to add project."
            }
        case .runProfileResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "run_profile_result") else { return }
            logger.info("[RunProfiles] received result id=\(result.clientRequestID.uuidString, privacy: .public) ok=\(result.ok, privacy: .public) project=\(result.projectID.uuidString, privacy: .public) profiles=\(result.profiles?.count ?? 0, privacy: .public) task=\(result.task?.taskId.uuidString ?? "<nil>", privacy: .public) error=\(result.errorMessage ?? "<nil>", privacy: .public)")
            applyRunProfileResult(result)
        case .runTaskUpdate(let update):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "run_task_update") else { return }
            upsertRunTask(update.task)
        case .skillCatalogResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "skill_catalog_result") else { return }
            applySkillCatalogResult(result)
        case .skillMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "skill_mutation_result") else { return }
            applySkillMutationResult(result)
        case .skillSourceMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "skill_source_mutation_result") else { return }
            applySkillSourceMutationResult(result)
        case .acpRegistryResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "acp_registry_result") else { return }
            applyACPRegistryResult(result)
        case .acpMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "acp_mutation_result") else { return }
            applyACPMutationResult(result)
        case .mcpConfigResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "mcp_config_result") else { return }
            applyMCPConfigResult(result)
        case .mcpMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "mcp_mutation_result") else { return }
            applyMCPMutationResult(result)
        case .ping:
            guard pairedDesktops.contains(where: { $0.pubkeyHex == inbound.fromHex }) else { return }
            Task { try? await self.client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

    private func applyRunProfileResult(_ result: RunProfileResultPayload) {
        inFlightRunProfileRequests.remove(result.clientRequestID)
        if let profiles = result.profiles {
            runProfilesByProject[result.projectID] = profiles
            logger.info("[RunProfiles] applied result profiles project=\(result.projectID.uuidString, privacy: .public) count=\(profiles.count, privacy: .public)")
        }
        if let task = result.task {
            upsertRunTask(task)
        }
        if result.ok {
            lastRunProfileError = nil
            Task { await self.requestSnapshot() }
        } else {
            lastRunProfileError = result.errorMessage ?? "Run profile operation failed."
        }
    }

    private func applySkillCatalogResult(_ result: SkillCatalogResultPayload) {
        guard pendingSkillCatalogRequestID == result.clientRequestID else { return }
        pendingSkillCatalogRequestID = nil
        skillCatalogLoading = false
        if result.ok {
            skillCatalog = result.plugins
            skillSources = result.sources
            skillCatalogError = nil
        } else {
            skillCatalogError = result.errorMessage ?? "Failed to load skills."
        }
    }

    private func applySkillMutationResult(_ result: SkillMutationResultPayload) {
        inFlightSkillMutations.remove(result.pluginID)
        skillCatalog = result.plugins
        skillSources = result.sources
        if result.ok {
            lastSkillError = nil
        } else {
            lastSkillError = result.errorMessage ?? "Skill operation failed."
        }
    }

    private func applySkillSourceMutationResult(_ result: SkillSourceMutationResultPayload) {
        if let key = skillSourceMutationKeys.removeValue(forKey: result.clientRequestID) {
            inFlightSkillSourceMutations.remove(key)
        }
        if let sourceID = result.sourceID {
            inFlightSkillSourceMutations.remove(sourceID)
        }
        skillCatalog = result.plugins
        skillSources = result.sources
        if result.ok {
            lastSkillError = nil
        } else {
            lastSkillError = result.errorMessage ?? "Skill source operation failed."
        }
    }

    private func applyACPRegistryResult(_ result: ACPRegistryResultPayload) {
        guard pendingACPRegistryRequestID == result.clientRequestID else { return }
        pendingACPRegistryRequestID = nil
        acpRegistryLoading = false
        if result.ok {
            acpRegistryAgents = result.registryAgents
            acpInstalledClients = result.installedClients
            acpRegistryError = nil
        } else {
            acpRegistryError = result.errorMessage ?? "Failed to load the agent registry."
        }
    }

    private func applyACPMutationResult(_ result: ACPMutationResultPayload) {
        if let key = acpMutationKeys.removeValue(forKey: result.clientRequestID) {
            inFlightACPMutations.remove(key)
        }
        acpRegistryAgents = result.registryAgents
        acpInstalledClients = result.installedClients
        if result.ok {
            lastACPError = nil
        } else {
            lastACPError = result.errorMessage ?? "Agent operation failed."
        }
    }

    private func applyMCPConfigResult(_ result: MCPConfigResultPayload) {
        guard pendingMCPConfigRequestID == result.clientRequestID else { return }
        pendingMCPConfigRequestID = nil
        mcpConfigLoading = false
        if result.ok {
            mcpServers = result.servers
            mcpConfigError = nil
        } else {
            mcpConfigError = result.errorMessage ?? "Failed to load MCP servers."
        }
    }

    private func applyMCPMutationResult(_ result: MCPMutationResultPayload) {
        inFlightMCPMutations.remove(result.serverName)
        mcpServers = result.servers
        if result.ok {
            lastMCPError = nil
        } else {
            lastMCPError = result.errorMessage ?? "MCP operation failed."
        }
    }

    private func upsertRunTask(_ task: MobileRunTaskSnapshot) {
        if let idx = runTasks.firstIndex(where: { $0.taskId == task.taskId }) {
            runTasks[idx] = task
        } else {
            runTasks.insert(task, at: 0)
        }
        runTasks.sort { $0.startedAt > $1.startedAt }
    }

    private func applySessionUpdate(_ update: SessionUpdatePayload) {
        if let previous = update.previousSessionID, previous != update.sessionID {
            if let carried = messagesBySession.removeValue(forKey: previous) {
                if let existing = messagesBySession[update.sessionID], !existing.isEmpty {
                    // The new session id already accumulated live messages
                    // before the redirect landed. Prepend the carried history,
                    // deduped by id, so the older messages aren't dropped.
                    let existingIDs = Set(existing.map(\.id))
                    messagesBySession[update.sessionID] =
                        carried.filter { !existingIDs.contains($0.id) } + existing
                } else {
                    messagesBySession[update.sessionID] = carried
                }
            }
            if sessionsWithMoreMessages.remove(previous) != nil {
                sessionsWithMoreMessages.insert(update.sessionID)
            }
            if loadingMoreSessions.remove(previous) != nil {
                loadingMoreSessions.insert(update.sessionID)
            }
            if activeSessionID == previous {
                activeSessionID = update.sessionID
            }
            sessions.removeAll { $0.id == previous }
        }

        if let summary = update.summary {
            upsertSessionSummary(summary)
        } else if let isStreaming = update.isStreaming {
            updateSessionStreamingFlag(sessionID: update.sessionID, isStreaming: isStreaming)
        }

        if let isThinking = update.isThinking {
            setSessionThinking(sessionID: update.sessionID, isThinking: isThinking)
        }
        // A session that is no longer streaming cannot still be thinking.
        if update.isStreaming == false {
            thinkingSessions.remove(update.sessionID)
        }

        switch update.kind {
        case .messageAppended:
            if let m = update.message {
                messagesBySession[update.sessionID, default: []].append(m)
            }
        case .messageUpdated:
            if let m = update.message,
               var list = messagesBySession[update.sessionID],
               let idx = list.firstIndex(where: { $0.id == m.id }) {
                list[idx] = m
                messagesBySession[update.sessionID] = list
            }
        case .streamingFinished:
            thinkingSessions.remove(update.sessionID)
            // Soft success cue, but only when the user is actually looking at
            // (or last looked at) the session that just finished. Avoids
            // buzzing on background-session completions.
            if update.sessionID == activeSessionID {
                MobileHaptics.streamFinished()
            }
        case .streamingStarted, .statusChanged:
            // Surface as a flag on the relevant session row.
            break
        }
    }

    private func upsertSessionSummary(_ summary: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }
        sessions.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func updateSessionStreamingFlag(sessionID: String, isStreaming: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = sessions[index]
        sessions[index] = SessionSummary(
            id: current.id,
            projectId: current.projectId,
            title: current.title,
            updatedAt: current.updatedAt,
            isPinned: current.isPinned,
            isArchived: current.isArchived,
            isStreaming: isStreaming,
            attention: current.attention,
            progress: current.progress,
            todos: current.todos,
            queuedMessages: current.queuedMessages,
            hasUncheckedCompletion: current.hasUncheckedCompletion
        )
    }

    private func setSessionThinking(sessionID: String, isThinking: Bool) {
        if isThinking {
            thinkingSessions.insert(sessionID)
        } else {
            thinkingSessions.remove(sessionID)
        }
    }

    func refreshFromDesktop(reason: String) async {
        await requestSnapshot(reason: reason)
    }

    private func requestSnapshot(reason: String = "manual") async {
        guard isPaired else {
            logger.info("[MobileSync] snapshot request skipped reason=\(reason, privacy: .public): mobile is not paired")
            return
        }
        let payload = RequestSnapshotPayload(activeSessionID: activeSessionID)
        do {
            try await client.send(.requestSnapshot(payload), toHex: pairedDesktopPubkey)
            logger.info("[MobileSync] requested snapshot reason=\(reason, privacy: .public) activeSession=\(self.activeSessionID ?? "<nil>", privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[MobileSync] snapshot request failed reason=\(reason, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func failPairing(_ message: String) {
        pairingStatus = .failed(message)
        MobileHaptics.connectionError()
    }

    private func triggerConnectionFeedback(
        from previous: RelayClient.ConnectionState,
        to next: RelayClient.ConnectionState
    ) {
        guard previous != next else { return }
        guard isPaired, pairingStatus != .inProgress else { return }

        switch next {
        case .connected:
            if case .reconnecting = previous {
                MobileHaptics.connected()
            }
        case .reconnecting:
            if previous == .connected {
                MobileHaptics.connectionError()
            }
        case .disconnected:
            if previous == .connected {
                MobileHaptics.connectionError()
            }
        case .connecting:
            break
        }
    }

    private func reportAPNsTokenIfPending() async {
        guard !pairedDesktops.isEmpty else {
            logger.info("[APNs] token report pending: mobile is not paired")
            return
        }
        guard let tokenHex = apnsTokenHex else {
            logger.info("[APNs] token report pending: no APNs token yet")
            return
        }
        guard let env = apnsEnvironment else {
            logger.info("[APNs] token report pending: no APNs environment yet")
            return
        }
        let payload = APNsTokenPayload(tokenHex: tokenHex, environment: env)
        for desktop in pairedDesktops {
            do {
                try await client.send(.apnsToken(payload), toHex: desktop.pubkeyHex)
                logger.info("[APNs] token reported to desktop tokenPrefix=\(String(tokenHex.prefix(12)), privacy: .public) environment=\(env, privacy: .public) desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            } catch {
                logger.error("[APNs] token report failed desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applySettingsUpdateLocally(_ update: MobileSettingsUpdatePayload) {
        guard let current = desktopSettings else { return }
        // Optimistically reflect a provider change, resolving its display name
        // from the synced options so the picker label updates immediately.
        let summarizationProvider = update.summarizationProvider ?? current.summarizationProvider
        let summarizationProviderDisplayName = update.summarizationProvider.flatMap { raw in
            current.availableSummarizationProviders?.first(where: { $0.id == raw })?.displayName
        } ?? current.summarizationProviderDisplayName
        desktopSettings = MobileSettingsSnapshot(
            selectedAgentProvider: update.selectedAgentProvider ?? current.selectedAgentProvider,
            selectedModel: update.selectedModel ?? current.selectedModel,
            selectedACPClientId: update.selectedACPClientId ?? current.selectedACPClientId,
            selectedEffort: update.selectedEffort ?? current.selectedEffort,
            permissionMode: update.permissionMode ?? current.permissionMode,
            summarizationProvider: summarizationProvider,
            summarizationProviderDisplayName: summarizationProviderDisplayName,
            openAISummarizationEndpoint: current.openAISummarizationEndpoint,
            openAISummarizationModel: update.openAISummarizationModel ?? current.openAISummarizationModel,
            notificationsEnabled: update.notificationsEnabled ?? current.notificationsEnabled,
            focusMode: update.focusMode ?? current.focusMode,
            autoArchiveEnabled: update.autoArchiveEnabled ?? current.autoArchiveEnabled,
            archiveRetentionDays: update.archiveRetentionDays ?? current.archiveRetentionDays,
            autoPreviewSettings: update.autoPreviewSettings ?? current.autoPreviewSettings,
            availableEfforts: current.availableEfforts,
            availableModels: current.availableModels,
            modelSections: current.modelSections,
            availableSummarizationProviders: current.availableSummarizationProviders,
            openAISummarizationModels: current.openAISummarizationModels
        )
    }

    // MARK: - Persistence

    private func loadPairedDesktops() {
        let defaults = UserDefaults.standard
        let savedMobilePubkey = defaults.string(forKey: Self.mobilePubkeyKey)
        if let savedMobilePubkey,
           !savedMobilePubkey.isEmpty,
           savedMobilePubkey != identity.publicKeyHex {
            logger.warning("[Pairing] clearing stale saved desktop pairing savedMobileKey=\(String(savedMobilePubkey.prefix(12)), privacy: .public) currentMobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            pairedDesktops = []
            setActiveDesktop(pubkeyHex: nil)
            savePairedDesktops()
            return
        }

        if let data = defaults.data(forKey: Self.pairedDesktopsKey),
           let decoded = try? JSONDecoder().decode([PairedDesktop].self, from: data) {
            pairedDesktops = Self.deduplicate(decoded)
        } else {
            let legacyPubkey = defaults.string(forKey: Self.legacyDesktopPubkeyKey) ?? ""
            let legacyName = defaults.string(forKey: Self.legacyDesktopNameKey) ?? ""
            if !legacyPubkey.isEmpty {
                pairedDesktops = [
                    PairedDesktop(
                        pubkeyHex: legacyPubkey,
                        displayName: legacyName,
                        pairedAt: .now,
                        lastSeen: nil
                    )
                ]
            }
        }

        let preferred = defaults.string(forKey: Self.activeDesktopPubkeyKey)
            ?? defaults.string(forKey: Self.legacyDesktopPubkeyKey)
        setActiveDesktop(pubkeyHex: preferred)
        if !pairedDesktops.isEmpty {
            savePairedDesktops()
        }
    }

    private func savePairedDesktops() {
        let defaults = UserDefaults.standard
        if pairedDesktops.isEmpty {
            defaults.removeObject(forKey: Self.pairedDesktopsKey)
            defaults.removeObject(forKey: Self.activeDesktopPubkeyKey)
            defaults.removeObject(forKey: Self.legacyDesktopPubkeyKey)
            defaults.removeObject(forKey: Self.legacyDesktopNameKey)
            defaults.removeObject(forKey: Self.mobilePubkeyKey)
        } else {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(pairedDesktops) {
                defaults.set(data, forKey: Self.pairedDesktopsKey)
            }
            defaults.set(pairedDesktopPubkey, forKey: Self.activeDesktopPubkeyKey)
            defaults.set(pairedDesktopPubkey, forKey: Self.legacyDesktopPubkeyKey)
            defaults.set(pairedDesktopName, forKey: Self.legacyDesktopNameKey)
            defaults.set(identity.publicKeyHex, forKey: Self.mobilePubkeyKey)
        }
    }

    private func setActiveDesktop(pubkeyHex: String?) {
        let resolved = pubkeyHex.flatMap { requested in
            pairedDesktops.first { $0.pubkeyHex == requested }
        } ?? pairedDesktops.first

        pairedDesktopPubkey = resolved?.pubkeyHex ?? ""
        pairedDesktopName = resolved?.displayName ?? ""
        isPaired = resolved != nil
    }

    private func upsertPairedDesktop(_ desktop: PairedDesktop) {
        if let index = pairedDesktops.firstIndex(where: { $0.pubkeyHex == desktop.pubkeyHex }) {
            let existing = pairedDesktops[index]
            pairedDesktops[index] = PairedDesktop(
                pubkeyHex: desktop.pubkeyHex,
                displayName: desktop.displayName,
                pairedAt: existing.pairedAt,
                lastSeen: desktop.lastSeen ?? existing.lastSeen
            )
        } else {
            pairedDesktops.append(desktop)
        }
    }

    private func acceptsActiveDesktopPayload(from pubkeyHex: String, type: String) -> Bool {
        guard pubkeyHex == pairedDesktopPubkey else {
            logger.info("[Pairing] ignoring \(type, privacy: .public) from inactive desktopKey=\(String(pubkeyHex.prefix(12)), privacy: .public)")
            return false
        }
        return true
    }

    private func removePairedDesktopAfterRemoteUnpair(_ desktop: PairedDesktop) async {
        let wasActive = desktop.pubkeyHex == pairedDesktopPubkey
        pairedDesktops.removeAll { $0.pubkeyHex == desktop.pubkeyHex }
        await client.removePeer(desktop.pubkeyHex)
        if wasActive {
            clearDesktopMirror()
            setActiveDesktop(pubkeyHex: pairedDesktops.first?.pubkeyHex)
        } else {
            setActiveDesktop(pubkeyHex: pairedDesktopPubkey)
        }
        savePairedDesktops()
        if wasActive, isPaired {
            await requestSnapshot()
            await reportAPNsTokenIfPending()
        }
    }

    private static func deduplicate(_ desktops: [PairedDesktop]) -> [PairedDesktop] {
        var seen: Set<String> = []
        var result: [PairedDesktop] = []
        for desktop in desktops {
            guard !desktop.pubkeyHex.isEmpty, !seen.contains(desktop.pubkeyHex) else { continue }
            seen.insert(desktop.pubkeyHex)
            result.append(desktop)
        }
        return result
    }
}

@MainActor
enum MobileHaptics {
    static func buttonTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func qrScanned() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func connected() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func connectionError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Soft success cue when the desktop agent finishes a turn.
    static func streamFinished() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning cue for things that block progress until the user acts:
    /// permission prompts, AskUserQuestion, and ExitPlanMode confirmation.
    static func attentionNeeded() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
