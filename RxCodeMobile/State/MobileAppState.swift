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
    /// The relay server URL this desktop was paired through.
    var relayURL: String?

    /// Composite id: same Mac paired via different relays produces distinct entries.
    var id: String {
        let normalizedRelay = (relayURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(pubkeyHex)::\(normalizedRelay)"
    }

    /// Human-readable relay host for display (e.g. "relay.example.com").
    var relayDisplayName: String? {
        guard let urlString = relayURL,
              let url = URL(string: urlString),
              let host = url.host else { return nil }
        return host
    }
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
    /// Auto-detected runnables (Xcode schemes, npm scripts, Make targets) per
    /// project. Produced by the desktop's `RunProfileDetector` and requested on
    /// demand when the run profile screen opens — never computed on mobile.
    @Published var detectedRunnablesByProject: [UUID: DetectedRunnables] = [:]
    /// Projects with an in-flight detection request, keyed by project id.
    @Published var runnableDetectInFlight: Set<UUID> = []
    @Published var runnableDetectError: String?
    var pendingRunnableDetectRequestID: UUID?

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
    var pendingSkillCatalogRequestID: UUID?
    var skillSourceMutationKeys: [UUID: String] = [:]

    // MARK: - Remote desktop config: ACP agent clients

    @Published var acpRegistryAgents: [MobileACPRegistryAgent] = []
    @Published var acpInstalledClients: [MobileACPClient] = []
    @Published var acpRegistryLoading = false
    @Published var acpRegistryError: String?
    /// Registry-agent ids or installed-client ids with an in-flight mutation.
    @Published var inFlightACPMutations: Set<String> = []
    @Published var lastACPError: String?
    var pendingACPRegistryRequestID: UUID?
    /// Maps an ACP mutation request id to the identity key tracked in
    /// `inFlightACPMutations`, so the result clears the right row.
    var acpMutationKeys: [UUID: String] = [:]

    // MARK: - Remote desktop config: MCP servers

    @Published var mcpServers: [MobileMCPServer] = []
    @Published var mcpConfigLoading = false
    @Published var mcpConfigError: String?
    /// Server names with an in-flight add/remove/toggle request.
    @Published var inFlightMCPMutations: Set<String> = []
    @Published var lastMCPError: String?
    var pendingMCPConfigRequestID: UUID?
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
    /// Sessions whose initial message page is being refreshed after opening the
    /// chat detail view.
    @Published var loadingThreadMessageSessions: Set<String> = []
    /// Maps an outstanding load-more request ID to its session, so a late
    /// `more_messages` reply lands on the right thread.
    var pendingLoadMoreRequests: [UUID: String] = [:]
    /// Messages per history page — must match the desktop's expectation.
    static let messagePageSize = 30
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
    /// Whether the mobile app has received its first snapshot from the desktop
    /// since launch or pairing. Used to show a loading state instead of
    /// "No Projects" when waiting for the initial sync.
    @Published var hasReceivedInitialSnapshot: Bool = false
    var pendingSearchID: UUID?
    var searchDebounceTask: Task<Void, Never>?

    /// Backing data for the thread "View Changes" sheet — thread file edits and
    /// uncommitted git changes for one thread. Nil until first loaded; carries
    /// its own `sessionID` so a stale result for another thread is ignored.
    @Published var threadChanges: ThreadChangesResultPayload?
    @Published var isLoadingThreadChanges: Bool = false
    var pendingThreadChangesID: UUID?

    @Published var remoteFolderRoot: RemoteFolderNode?
    @Published var remoteFolderIsLoading = false
    @Published var remoteFolderError: String?
    @Published var remoteProjectCreateInFlight = false
    @Published var remoteProjectCreateError: String?
    @Published var lastCreatedProjectID: UUID?
    var pendingFolderTreeRequestID: UUID?
    var pendingCreateProjectRequestID: UUID?

    var identity: DeviceIdentity
    var client: SyncClient
    let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileAppState")
    var eventTask: Task<Void, Never>?
    var pairingTimeoutTask: Task<Void, Never>?
    var apnsTokenHex: String?
    var apnsEnvironment: String?
    var clientStarted = false

    static let pairingTimeoutSeconds: UInt64 = 25
    static let pairedDesktopsKey = "mobileSync.pairedDesktops"
    static let activeDesktopPubkeyKey = "mobileSync.activeDesktopPubkey"
    static let legacyDesktopPubkeyKey = "mobileSync.desktopPubkey"
    static let legacyDesktopNameKey = "mobileSync.desktopName"
    static let mobilePubkeyKey = "mobileSync.mobilePubkey"
    static var currentAPNsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    init() {
        // UI-test seam: rewrites the relay URL and clears stale pairing before
        // the reads below. No-op outside Debug builds / UI-test launches.
        UITestSupport.applyDefaultsOverrides()
        let stored = UserDefaults.standard.string(forKey: "mobileSync.relayURL")
        let initial = URL(string: stored ?? Self.defaultRelayURLString)
            ?? URL(string: Self.defaultRelayURLString)!
        self.relayURL = initial
        if UITestSupport.isActive {
            // UI tests run an unsigned build, where the shared Keychain access
            // group is unavailable and `loadOrCreate` would trap. The mock
            // relay learns the mobile public key from each envelope, so an
            // ephemeral per-launch identity is sufficient and skips the Keychain.
            self.identity = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        } else {
            do {
                // Shared access group lets the Notification Service Extension
                // read the private key for decrypting APNs alerts. The bare
                // group suffix is matched against the (already-expanded)
                // entitlement — never pass the literal `$(AppIdentifierPrefix)…`
                // here, that's a build-time substitution, meaningless at runtime.
                self.identity = try DeviceIdentity.loadOrCreate(
                    accessGroup: Self.keychainAccessGroup
                )
            } catch {
                Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileAppState")
                    .error("[MobileIdentity] load failed accessGroup=\(Self.keychainAccessGroup, privacy: .public): \(error.localizedDescription, privacy: .public)")
                fatalError("Failed to load mobile device identity: \(error)")
            }
        }
        self.client = SyncClient(identity: identity, relayURL: initial)
        logger.info("[MobileIdentity] loaded publicKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public) accessGroup=\(Self.keychainAccessGroup, privacy: .public)")
        loadPairedDesktops()
        #if DEBUG
        applyUITestPairingIfNeeded()
        #endif
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
        // Match both pubkey and relay to identify the correct pairing when the
        // same Mac is paired via multiple relays.
        let currentRelay = relayURL.absoluteString.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return pairedDesktops.first { desktop in
            guard desktop.pubkeyHex == pairedDesktopPubkey else { return false }
            let desktopRelay = (desktop.relayURL ?? "").lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return desktopRelay == currentRelay
        } ?? pairedDesktops.first { $0.pubkeyHex == pairedDesktopPubkey }
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

    func startClient() async {
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
