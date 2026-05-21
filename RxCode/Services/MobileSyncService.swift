import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

/// One per-activity Live Activity push token registered by a paired mobile.
/// The desktop targets `update`/`end` pushes at `token`, scoped to `sessionID`.
struct LiveActivityTokenRef: Codable, Sendable, Hashable {
    var activityID: String
    var sessionID: String
    var token: String
}

/// One paired mobile device. Persisted to
/// `~/Library/Application Support/RxCode/paired_devices.json`.
struct PairedDevice: Codable, Identifiable, Sendable, Hashable {
    var pubkeyHex: String
    var displayName: String
    var platform: String
    var apnsToken: String?
    var apnsEnvironment: String?
    /// Device-wide Live Activity push-to-start token (iOS 17.2+). Lets the
    /// desktop spawn a job Live Activity remotely. Optional for wire/forward
    /// compatibility with paired-device files written before Live Activities.
    var liveActivityStartToken: String?
    /// Per-activity Live Activity update tokens, one per running job activity.
    var liveActivityTokens: [LiveActivityTokenRef]?
    var pairedAt: Date
    var lastSeen: Date?

    var id: String { pubkeyHex }
}

/// Result of a pairing handshake propagated to the SwiftUI pairing sheet.
enum PairingOutcome: Sendable {
    case pending
    case received(PairRequestPayload)
    case accepted(PairedDevice)
    case cancelled
}

enum MobilePushError: LocalizedError {
    case missingDeviceToken
    case unknownPeer
    case invalidRelayURL
    case relayRejected(status: Int, body: String)
    case apnsRejected(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingDeviceToken:
            "This device has not registered a push token yet."
        case .unknownPeer:
            "This device is not available in the encrypted peer list."
        case .invalidRelayURL:
            "The relay URL cannot be converted to a push endpoint."
        case .relayRejected(let status, let body):
            "Relay rejected the push request (\(status)): \(body)"
        case .apnsRejected(let status, let reason):
            "APNs rejected the notification (\(status)): \(reason)"
        }
    }
}

/// Bridges the desktop app to paired mobile devices over the E2E-encrypted
/// relay channel. Owns the long-term `DeviceIdentity`, the `SyncClient`, and
/// the persistent paired-device list.
@MainActor
final class MobileSyncService: ObservableObject {

    static let shared = MobileSyncService()

    @Published var pairedDevices: [PairedDevice] = []
    @Published var connectionState: RelayClient.ConnectionState = .disconnected
    @Published var isPairing: Bool = false
    @Published var pendingPairing: PairRequestPayload?
    @Published var relayURL: URL

    let logger = Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
    let identity: DeviceIdentity
    var client: SyncClient
    var subscribedSessions: [String: String] = [:]
    var eventTask: Task<Void, Never>?
    var pairingToken: PairingToken?
    var pairingContinuation: CheckedContinuation<PairingOutcome, Never>?

    /// The single AppState reference is set in init order from RxCodeApp,
    /// because AppState owns the storage layer and the streaming loop.
    weak var appState: AnyObject?

    // MARK: - Live Activity & widget state

    /// Resolves a project's display name for Live Activity attributes. Set by
    /// `AppState` after initialization; `nil` before that.
    var projectNameResolver: (@MainActor (UUID) -> String?)?
    /// Supplies the current Claude Code / Codex 5-hour usage for the widget
    /// background push. Set by `AppState`; `nil` before that.
    var usageSnapshotProvider: (@MainActor () -> (cc: Double?, codex: Double?))?

    /// Session ids currently streaming — the live job count for the widget.
    var streamingSessionIDs: Set<String> = []
    /// Every job tracked by the single aggregate Live Activity: those still
    /// running plus recently finished ones, in start order.
    var trackedJobs: [JobContent] = []
    /// `true` once a foregrounded device reported it started the activity
    /// locally; suppresses the push-to-start until the activity goes away.
    var jobsActivityLocallyStarted = false
    /// Signature of the content-state last pushed, so an update only fires on
    /// a real change rather than on every session event.
    var lastPushedJobsSignature = ""
    /// Pending deferred push-to-start. The push-to-start is delayed briefly so
    /// a foregrounded device can start the activity locally instead; this task
    /// is cancelled once a device reports it did.
    var pendingStartTask: Task<Void, Never>?
    /// Last widget job count pushed, so a widget push only fires on a change.
    var lastWidgetJobCount: Int = -1

    init() {
        // Persisted relay URL or sensible default for self-host.
        let stored = UserDefaults.standard.string(forKey: "mobileSync.relayURL")
        let initial = URL(string: stored ?? "ws://localhost:8787") ?? URL(string: "ws://localhost:8787")!
        self.relayURL = initial
        do {
            self.identity = try DeviceIdentity.loadOrCreate()
        } catch {
            Self.logFatalKeychain(error)
            fatalError("Failed to load device identity: \(error)")
        }
        self.client = SyncClient(identity: identity, relayURL: initial)
        loadPairedDevices()
    }

    static func logFatalKeychain(_ error: Error) {
        Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
            .fault("device-identity load failed: \(String(describing: error))")
    }

    // MARK: - Public API

    var localPublicKeyHex: String { identity.publicKeyHex }
    var localDeviceName: String { Host.current().localizedName ?? "Mac" }

    /// Begin (or resume) the relay connection. Safe to call multiple times.
    func start() {
        Task { @MainActor in
            logger.info("[MobileSync] starting relay=\(self.relayURL.absoluteString, privacy: .public) pairedDevices=\(self.pairedDevices.count, privacy: .public) desktopKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            for device in pairedDevices {
                do {
                    try await client.addPeer(device.pubkeyHex)
                    logger.info("[MobileSync] added paired peer mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                } catch {
                    logger.error("[MobileSync] failed to add paired peer mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // Subscribe to events BEFORE calling start() so we don't miss the
            // initial .connecting / .connected state transitions.
            let events = await client.events()
            eventTask?.cancel()
            eventTask = Task { @MainActor in
                for await event in events {
                    self.handle(event: event)
                }
            }
            await client.start()
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        Task { await client.stop() }
    }

    /// Update the configured relay URL, persist it, and reconnect.
    func updateRelay(url: URL) {
        guard url != relayURL else { return }
        logger.info("[MobileSync] relay URL changed from \(self.relayURL.absoluteString, privacy: .public) to \(url.absoluteString, privacy: .public)")
        UserDefaults.standard.set(url.absoluteString, forKey: "mobileSync.relayURL")
        relayURL = url
        eventTask?.cancel()
        eventTask = nil
        let oldClient = client
        client = SyncClient(identity: identity, relayURL: url)
        connectionState = .disconnected
        Task { await oldClient.stop() }
        start()
    }

    // MARK: - Pairing

    /// Generate a fresh pairing token + show it as QR. Token expires in 2 min.
    func beginPairing() -> PairingToken {
        let token = PairingToken(
            relayURL: relayURL.absoluteString,
            desktopPubkeyHex: identity.publicKeyHex,
            oneTimeSecretHex: PairingToken.makeOneTimeSecret(),
            expiresAt: Date.now.addingTimeInterval(120),
            desktopName: localDeviceName
        )
        pairingToken = token
        isPairing = true
        pendingPairing = nil
        return token
    }

    /// Wait until a mobile finishes the pairing handshake. Returns when the
    /// user has either approved or cancelled the pending request.
    func awaitPairing() async -> PairingOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<PairingOutcome, Never>) in
            pairingContinuation = continuation
        }
    }

    /// Accept the pending pair request shown to the user in the pairing sheet.
    func acceptPendingPairing() async {
        guard let pending = pendingPairing else { return }
        let device = PairedDevice(
            pubkeyHex: pending.mobilePubkeyHex,
            displayName: pending.displayName,
            platform: pending.platform,
            apnsToken: nil,
            apnsEnvironment: nil,
            pairedAt: .now,
            lastSeen: .now
        )
        pairedDevices.removeAll { $0.pubkeyHex == device.pubkeyHex }
        pairedDevices.append(device)
        savePairedDevices()
        try? await client.addPeer(device.pubkeyHex)
        let ack = PairAckPayload(accepted: true, desktopName: localDeviceName)
        try? await client.send(.pairAck(ack), toHex: device.pubkeyHex)
        isPairing = false
        pendingPairing = nil
        pairingToken = nil
        pairingContinuation?.resume(returning: .accepted(device))
        pairingContinuation = nil
    }

    func cancelPairing() {
        Task {
            if let pending = pendingPairing {
                let ack = PairAckPayload(accepted: false, desktopName: localDeviceName, reason: "rejected")
                try? await client.addPeer(pending.mobilePubkeyHex)
                try? await client.send(.pairAck(ack), toHex: pending.mobilePubkeyHex)
                await client.removePeer(pending.mobilePubkeyHex)
            }
        }
        isPairing = false
        pendingPairing = nil
        pairingToken = nil
        pairingContinuation?.resume(returning: .cancelled)
        pairingContinuation = nil
    }

    /// Remove a paired device and notify it before forgetting its pubkey.
    func unpair(_ device: PairedDevice) async {
        try? await client.send(.unpair(UnpairPayload(reason: "desktop")), toHex: device.pubkeyHex)
        pairedDevices.removeAll { $0.pubkeyHex == device.pubkeyHex }
        savePairedDevices()
        subscribedSessions.removeValue(forKey: device.pubkeyHex)
        await client.removePeer(device.pubkeyHex)
    }

    // MARK: - Notification fan-out

    /// Send a notification to every paired device.
    ///
    /// Two delivery paths run for each broadcast:
    /// - the live WebSocket relay channel reaches devices that are currently
    ///   connected and foregrounded;
    /// - a best-effort APNs push reaches devices that are backgrounded or
    ///   offline, so a finished thread still surfaces a banner.
    func broadcastNotification(_ payload: NotificationPayload) {
        Task {
            await client.broadcast(.notification(payload))
            await fanoutAPNs(payload)
        }
    }

    /// Best-effort APNs fan-out: submit one encrypted alert per paired device
    /// that has registered a push token. Per-device failures are logged and
    /// swallowed — the live channel above remains the primary path.
    func fanoutAPNs(_ payload: NotificationPayload) async {
        let devices = pairedDevices.filter { ($0.apnsToken?.isEmpty == false) }
        guard !devices.isEmpty else { return }
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            logger.error("[APNs] cannot derive push endpoint from relay URL \(self.relayURL.absoluteString, privacy: .public)")
            return
        }
        for device in devices {
            do {
                try await sendAPNsPush(payload, to: device, pushURL: pushURL)
            } catch {
                logger.error("[APNs] fan-out failed deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Encrypt `payload` for one device and POST it to the relay `/push`
    /// endpoint. Throws on a missing token, unknown peer, or relay/APNs
    /// rejection so callers can log the specific failure.
    func sendAPNsPush(_ payload: NotificationPayload, to device: PairedDevice, pushURL: URL) async throws {
        guard let token = device.apnsToken, !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        guard let peer = await client.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }

        let plaintext = AlertPlaintext(
            title: payload.title,
            body: payload.body,
            sessionID: payload.sessionID,
            projectID: payload.projectID,
            kind: payload.kind.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = APNsPushRequest(
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: payload.kind.rawValue,
            collapseID: Self.notificationCollapseID(for: payload, device: device)
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("[APNs] sending push kind=\(payload.kind.rawValue, privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }
        let pushResponse = try JSONDecoder().decode(APNsPushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.apnsRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason
            )
        }
    }

    /// Send one APNs-backed test notification to a paired device.
    func sendTestNotification(to device: PairedDevice) async throws {
        guard let token = device.apnsToken, !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        guard let peer = await client.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            throw MobilePushError.invalidRelayURL
        }

        logger.info("[APNs] sending test push deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public) environment=\(device.apnsEnvironment ?? "<nil>", privacy: .public) sender=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        let plaintext = AlertPlaintext(
            title: "RxCode test notification",
            body: "Notifications are working for \(device.displayName).",
            kind: NotificationPayload.Kind.generic.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = APNsPushRequest(
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: "test_notification",
            collapseID: Self.testNotificationCollapseID(for: device)
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }

        let pushResponse = try JSONDecoder().decode(APNsPushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.apnsRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason
            )
        }
    }

    // MARK: - Streaming hooks

    /// Called by AppState's streaming loop after each StreamEvent is folded
    /// into local state.
    func broadcastSessionUpdate(
        sessionID: String,
        kind: SessionUpdatePayload.Kind,
        message: ChatMessage?,
        isStreaming: Bool?,
        isThinking: Bool? = nil,
        summary: RxCodeSync.SessionSummary? = nil,
        previousSessionID: String? = nil
    ) {
        Task {
            let payload = SessionUpdatePayload(
                sessionID: sessionID,
                kind: kind,
                message: message,
                isStreaming: isStreaming,
                isThinking: isThinking,
                summary: summary,
                previousSessionID: previousSessionID
            )
            await client.broadcast(.sessionUpdate(payload))
        }
        updateJobTracking(
            sessionID: sessionID,
            kind: kind,
            isStreaming: isStreaming,
            summary: summary,
            previousSessionID: previousSessionID
        )
    }

    /// Mirror the desktop's current `AskUserQuestion` queue to every paired
    /// device. Sent whenever a question is queued or resolved so mobile can
    /// surface the same queue banner + question sheet.
    func broadcastQuestionQueue(_ questions: [PendingQuestionPayload]) {
        Task {
            await client.broadcast(.questionQueue(QuestionQueuePayload(questions: questions)))
        }
    }

    func broadcastRunTaskUpdate(_ task: MobileRunTaskSnapshot) {
        Task {
            await client.broadcast(.runTaskUpdate(RunTaskUpdatePayload(task: task)))
        }
    }

    // MARK: - Persistence

    var pairedDevicesURL: URL {
        AppSupport.bundleScopedURL.appendingPathComponent("paired_devices.json")
    }

    func loadPairedDevices() {
        guard let data = try? Data(contentsOf: pairedDevicesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        pairedDevices = (try? decoder.decode([PairedDevice].self, from: data)) ?? []
    }

    func savePairedDevices() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(pairedDevices)
            try data.write(to: pairedDevicesURL, options: .atomic)
        } catch {
            logger.error("save paired_devices.json: \(error.localizedDescription)")
        }
    }

    static func pushEndpointURL(from relayURL: URL) -> URL? {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }

        var path = components.path
        if path.isEmpty || path == "/" {
            path = "/push"
        } else {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = trimmed.split(separator: "/").last == "ws"
                ? trimmed.split(separator: "/").dropLast().joined(separator: "/")
                : trimmed
            path = "/" + ([base, "push"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        components.path = path
        components.queryItems = nil
        return components.url
    }

    static func responseBodyString(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Empty response" : raw
    }

    static func testNotificationCollapseID(for device: PairedDevice) -> String {
        "rxcode-test-\(device.pubkeyHex.prefix(32))"
    }

    /// Collapse repeated alerts for the same session + kind so a device shows
    /// the latest banner instead of stacking one per stream event.
    static func notificationCollapseID(for payload: NotificationPayload, device: PairedDevice) -> String {
        let scope = payload.sessionID ?? "global"
        return "rxcode-\(payload.kind.rawValue)-\(scope.prefix(48))"
    }
}

struct APNsPushRequest: Codable {
    let deviceToken: String
    let encryptedAlert: String
    let category: String?
    let collapseID: String?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case encryptedAlert = "encrypted_alert"
        case category
        case collapseID = "collapse_id"
    }
}

struct APNsPushResponse: Codable {
    let statusCode: Int
    let reason: String
    let apnsID: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case reason
        case apnsID = "apns_id"
    }
}

extension Notification.Name {
    static let mobileSyncSnapshotRequested = Notification.Name("mobileSync.snapshotRequested")
    static let mobileSyncUserMessageReceived = Notification.Name("mobileSync.userMessageReceived")
    static let mobileSyncCancelStreamRequested = Notification.Name("mobileSync.cancelStreamRequested")
    static let mobileSyncRemoveQueuedRequested = Notification.Name("mobileSync.removeQueuedRequested")
    static let mobileSyncNewSessionRequested = Notification.Name("mobileSync.newSessionRequested")
    static let mobileSyncThreadActionRequested = Notification.Name("mobileSync.threadActionRequested")
    static let mobileSyncLoadMoreMessagesRequested = Notification.Name("mobileSync.loadMoreMessagesRequested")
    static let mobileSyncSearchRequested = Notification.Name("mobileSync.searchRequested")
    static let mobileSyncThreadChangesRequested = Notification.Name("mobileSync.threadChangesRequested")
    static let mobileSyncSettingsUpdateReceived = Notification.Name("mobileSync.settingsUpdateReceived")
    static let mobileSyncPermissionResponse = Notification.Name("mobileSync.permissionResponse")
    static let mobileSyncQuestionAnswerReceived = Notification.Name("mobileSync.questionAnswerReceived")
    static let mobileSyncPlanDecisionReceived = Notification.Name("mobileSync.planDecisionReceived")
    static let mobileSyncBranchOpRequested = Notification.Name("mobileSync.branchOpRequested")
    static let mobileSyncFolderTreeRequested = Notification.Name("mobileSync.folderTreeRequested")
    static let mobileSyncCreateProjectRequested = Notification.Name("mobileSync.createProjectRequested")
    static let mobileSyncRunProfileMutationRequested = Notification.Name("mobileSync.runProfileMutationRequested")
    static let mobileSyncRunProfileRunRequested = Notification.Name("mobileSync.runProfileRunRequested")
    static let mobileSyncRunProfileStopRequested = Notification.Name("mobileSync.runProfileStopRequested")
    static let mobileSyncSkillCatalogRequested = Notification.Name("mobileSync.skillCatalogRequested")
    static let mobileSyncSkillMutationRequested = Notification.Name("mobileSync.skillMutationRequested")
    static let mobileSyncSkillSourceMutationRequested = Notification.Name("mobileSync.skillSourceMutationRequested")
    static let mobileSyncACPRegistryRequested = Notification.Name("mobileSync.acpRegistryRequested")
    static let mobileSyncACPMutationRequested = Notification.Name("mobileSync.acpMutationRequested")
    static let mobileSyncMCPConfigRequested = Notification.Name("mobileSync.mcpConfigRequested")
    static let mobileSyncMCPMutationRequested = Notification.Name("mobileSync.mcpMutationRequested")
}
