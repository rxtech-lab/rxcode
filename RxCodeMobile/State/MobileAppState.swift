import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import UIKit
import os.log

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
    @Published var connectionState: RelayClient.ConnectionState = .disconnected
    @Published var relayURL: URL
    @Published var pairingStatus: PairingStatus = .idle

    @Published var projects: [Project] = []
    @Published var sessions: [SessionSummary] = []
    @Published var branchBriefings: [MobileBranchBriefing] = []
    @Published var threadSummaries: [MobileThreadSummary] = []
    @Published var desktopSettings: MobileSettingsSnapshot?
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var activeSessionID: String?
    @Published var pendingPermission: PermissionRequestPayload?

    private var identity: DeviceIdentity
    private var client: SyncClient
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileAppState")
    private var eventTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var apnsTokenHex: String?
    private var apnsEnvironment: String?
    private var clientStarted = false

    static let pairingTimeoutSeconds: UInt64 = 25

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
        loadPairedDesktop()
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

    func start() {
        Task { @MainActor in
            await startClient()
        }
    }

    private func startClient() async {
        clientStarted = true
        if !pairedDesktopPubkey.isEmpty {
            try? await client.addPeer(pairedDesktopPubkey)
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
            let payload = RequestSnapshotPayload(activeSessionID: activeSessionID)
            try? await client.send(.requestSnapshot(payload), toHex: pairedDesktopPubkey)
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
        if !isPaired { pairingStatus = .idle }
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
                guard !self.isPaired else { return }
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

    func requestNewSession(projectID: UUID, initialText: String? = nil) async {
        guard isPaired else { return }
        let payload = NewSessionRequestPayload(projectID: projectID, initialText: initialText)
        try? await client.send(.newSessionRequest(payload), toHex: pairedDesktopPubkey)
    }

    func subscribe(to sessionID: String?) async {
        activeSessionID = sessionID
        guard isPaired else { return }
        let payload = SubscribeSessionPayload(sessionID: sessionID)
        try? await client.send(.subscribeSession(payload), toHex: pairedDesktopPubkey)
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

    func updateDesktopSettings(_ update: MobileSettingsUpdatePayload) async {
        guard isPaired else { return }
        applySettingsUpdateLocally(update)
        try? await client.send(.settingsUpdate(update), toHex: pairedDesktopPubkey)
    }

    func refreshSnapshot() async {
        await requestSnapshot()
    }

    func reportAPNsToken(hex: String, environment: String) {
        logger.info("[APNs] received token from app delegate tokenPrefix=\(String(hex.prefix(12)), privacy: .public) environment=\(environment, privacy: .public)")
        apnsTokenHex = hex
        apnsEnvironment = environment
        Task { await reportAPNsTokenIfPending() }
    }

    func unpair() async {
        let desktopHex = pairedDesktopPubkey
        if !desktopHex.isEmpty {
            try? await client.send(.unpair(UnpairPayload(reason: "mobile")), toHex: desktopHex)
        }
        await clearPairing(removePeerHex: desktopHex)
    }

    private func clearPairing(removePeerHex hex: String?) async {
        if let hex, !hex.isEmpty {
            await client.removePeer(hex)
        }
        pairedDesktopPubkey = ""
        pairedDesktopName = ""
        isPaired = false
        projects = []
        sessions = []
        branchBriefings = []
        threadSummaries = []
        desktopSettings = nil
        messagesBySession = [:]
        activeSessionID = nil
        pendingPermission = nil
        savePairedDesktop()
        await resetIdentityAndClient()
    }

    // MARK: - Inbound events

    private func handle(_ event: RelayClient.Event) {
        switch event {
        case .stateChanged(let state):
            logger.info("relay connection state changed: \(String(describing: state), privacy: .public)")
            let previous = connectionState
            connectionState = state
            triggerConnectionFeedback(from: previous, to: state)
            if case .connected = state, isPaired {
                Task { await self.requestSnapshot() }
            }
        case .deliveryFailed:
            break
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
                pairedDesktopPubkey = inbound.fromHex
                pairedDesktopName = ack.desktopName
                isPaired = true
                pairingStatus = .idle
                logger.info("[Pairing] accepted desktop=\(ack.desktopName, privacy: .public) desktopKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
                MobileHaptics.connected()
                savePairedDesktop()
                Task {
                    await self.requestSnapshot()
                    await self.reportAPNsTokenIfPending()
                }
            } else {
                isPaired = false
                failPairing("Your Mac declined the pairing request.")
            }
        case .unpair:
            guard inbound.fromHex == pairedDesktopPubkey else { return }
            Task { await self.clearPairing(removePeerHex: inbound.fromHex) }
        case .snapshot(let snap):
            projects = snap.projects
            sessions = snap.sessions
            branchBriefings = snap.branchBriefings ?? []
            threadSummaries = snap.threadSummaries ?? []
            desktopSettings = snap.settings
            if let active = snap.activeSessionID {
                if let messages = snap.activeSessionMessages {
                    messagesBySession[active] = messages
                } else if messagesBySession[active] == nil {
                    messagesBySession[active] = []
                }
                activeSessionID = active
            }
        case .sessionUpdate(let update):
            applySessionUpdate(update)
        case .permissionRequest(let req):
            pendingPermission = req
        case .notification:
            // Foreground notifications arriving over WS — iOS won't show a
            // banner automatically; UI surfaces these in a toast/badge.
            break
        case .ping:
            Task { try? await self.client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

    private func applySessionUpdate(_ update: SessionUpdatePayload) {
        if let previous = update.previousSessionID, previous != update.sessionID {
            if let messages = messagesBySession.removeValue(forKey: previous),
               messagesBySession[update.sessionID] == nil {
                messagesBySession[update.sessionID] = messages
            }
            if activeSessionID == previous {
                activeSessionID = update.sessionID
            }
        }

        if let summary = update.summary {
            upsertSessionSummary(summary)
        } else if let isStreaming = update.isStreaming {
            updateSessionStreamingFlag(sessionID: update.sessionID, isStreaming: isStreaming)
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
        case .streamingStarted, .streamingFinished, .statusChanged:
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
            progress: current.progress
        )
    }

    private func requestSnapshot() async {
        guard isPaired else { return }
        let payload = RequestSnapshotPayload(activeSessionID: activeSessionID)
        try? await client.send(.requestSnapshot(payload), toHex: pairedDesktopPubkey)
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
        guard isPaired else {
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
        do {
            try await client.send(.apnsToken(payload), toHex: pairedDesktopPubkey)
            logger.info("[APNs] token reported to desktop tokenPrefix=\(String(tokenHex.prefix(12)), privacy: .public) environment=\(env, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[APNs] token report failed desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applySettingsUpdateLocally(_ update: MobileSettingsUpdatePayload) {
        guard let current = desktopSettings else { return }
        desktopSettings = MobileSettingsSnapshot(
            selectedAgentProvider: update.selectedAgentProvider ?? current.selectedAgentProvider,
            selectedModel: update.selectedModel ?? current.selectedModel,
            selectedACPClientId: update.selectedACPClientId ?? current.selectedACPClientId,
            selectedEffort: update.selectedEffort ?? current.selectedEffort,
            permissionMode: update.permissionMode ?? current.permissionMode,
            summarizationProvider: current.summarizationProvider,
            summarizationProviderDisplayName: current.summarizationProviderDisplayName,
            openAISummarizationEndpoint: current.openAISummarizationEndpoint,
            openAISummarizationModel: current.openAISummarizationModel,
            notificationsEnabled: update.notificationsEnabled ?? current.notificationsEnabled,
            focusMode: update.focusMode ?? current.focusMode,
            autoArchiveEnabled: update.autoArchiveEnabled ?? current.autoArchiveEnabled,
            archiveRetentionDays: update.archiveRetentionDays ?? current.archiveRetentionDays,
            autoPreviewSettings: update.autoPreviewSettings ?? current.autoPreviewSettings,
            availableEfforts: current.availableEfforts
        )
    }

    // MARK: - Persistence

    private func loadPairedDesktop() {
        pairedDesktopPubkey = UserDefaults.standard.string(forKey: "mobileSync.desktopPubkey") ?? ""
        pairedDesktopName = UserDefaults.standard.string(forKey: "mobileSync.desktopName") ?? ""
        let savedMobilePubkey = UserDefaults.standard.string(forKey: "mobileSync.mobilePubkey")
        if let savedMobilePubkey,
           !savedMobilePubkey.isEmpty,
           savedMobilePubkey != identity.publicKeyHex {
            logger.warning("[Pairing] clearing stale saved desktop pairing savedMobileKey=\(String(savedMobilePubkey.prefix(12)), privacy: .public) currentMobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            pairedDesktopPubkey = ""
            pairedDesktopName = ""
            savePairedDesktop()
        }
        isPaired = !pairedDesktopPubkey.isEmpty
    }

    private func savePairedDesktop() {
        if pairedDesktopPubkey.isEmpty {
            UserDefaults.standard.removeObject(forKey: "mobileSync.desktopPubkey")
            UserDefaults.standard.removeObject(forKey: "mobileSync.desktopName")
            UserDefaults.standard.removeObject(forKey: "mobileSync.mobilePubkey")
        } else {
            UserDefaults.standard.set(pairedDesktopPubkey, forKey: "mobileSync.desktopPubkey")
            UserDefaults.standard.set(pairedDesktopName, forKey: "mobileSync.desktopName")
            UserDefaults.standard.set(identity.publicKeyHex, forKey: "mobileSync.mobilePubkey")
        }
    }

    private func resetIdentityAndClient() async {
        let oldClient = client
        eventTask?.cancel()
        eventTask = nil
        await oldClient.stop()

        do {
            try DeviceIdentity.reset(accessGroup: Self.keychainAccessGroup)
            identity = try DeviceIdentity.loadOrCreate(accessGroup: Self.keychainAccessGroup)
            client = SyncClient(identity: identity, relayURL: relayURL)
            connectionState = .disconnected
            logger.info("[MobileIdentity] regenerated publicKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public) accessGroup=\(Self.keychainAccessGroup, privacy: .public)")
        } catch {
            logger.error("[MobileIdentity] reset failed accessGroup=\(Self.keychainAccessGroup, privacy: .public): \(error.localizedDescription, privacy: .public)")
            client = SyncClient(identity: identity, relayURL: relayURL)
            connectionState = .disconnected
        }

        if clientStarted {
            await startClient()
        }
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
}
