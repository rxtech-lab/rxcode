import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

/// The single aggregate Live Activity push token registered by a paired
/// mobile. The desktop targets `update`/`end` pushes at `token`.
struct LiveActivityTokenRef: Codable, Sendable, Hashable {
    var activityID: String
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
    /// The relay server URL this device was paired through.
    var relayURL: String?

    var id: String { pubkeyHex }

    /// Human-readable relay host for display (e.g. "relay.example.com").
    var relayDisplayName: String? {
        guard let urlString = relayURL,
              let url = URL(string: urlString),
              let host = url.host else { return nil }
        return host
    }
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

/// A saved relay server configuration, stored in UserDefaults.
struct SavedRelayServer: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var addedAt: Date
    /// Whether this relay should be connected (user preference).
    var isEnabled: Bool

    /// Human-readable relay host for display (e.g. "relay.example.com").
    var displayHost: String? {
        guard let parsed = URL(string: url), let host = parsed.host else { return nil }
        return host
    }

    init(id: UUID = UUID(), name: String, url: String, addedAt: Date = .now, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.addedAt = addedAt
        self.isEnabled = isEnabled
    }
}

/// Connection state for a single relay server.
struct RelayConnectionInfo: Identifiable {
    let id: UUID  // matches SavedRelayServer.id
    var state: RelayClient.ConnectionState
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
    @Published var savedRelayServers: [SavedRelayServer] = []
    /// Connection state per relay server (keyed by SavedRelayServer.id).
    @Published var relayConnectionStates: [UUID: RelayClient.ConnectionState] = [:]

    let logger = Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
    let identity: DeviceIdentity
    var client: SyncClient
    /// Additional clients for multi-relay support (keyed by SavedRelayServer.id).
    var additionalClients: [UUID: SyncClient] = [:]
    var additionalEventTasks: [UUID: Task<Void, Never>] = [:]
    var subscribedSessions: [String: String] = [:]
    var eventTask: Task<Void, Never>?
    var pairingToken: PairingToken?
    var pairingContinuation: CheckedContinuation<PairingOutcome, Never>?
    /// The relay server ID currently being used for pairing.
    var pairingRelayServerID: UUID?

    /// The single AppState reference is set in init order from RxCodeApp,
    /// because AppState owns the storage layer and the streaming loop.
    weak var appState: AnyObject?

    // MARK: - Live Activity & widget state

    /// Resolves a project's display name for Live Activity attributes. Set by
    /// `AppState` after initialization; `nil` before that.
    var projectNameResolver: (@MainActor (UUID) -> String?)?
    /// Supplies the current Claude Code / Codex usage for the widget
    /// background push. Set by `AppState`; `nil` before that.
    var usageSnapshotProvider: (@MainActor () -> (
        cc: Double?,
        ccWeekly: Double?,
        codex: Double?,
        codexWeekly: Double?
    ))?

    /// Pure state machine behind the aggregate Live Activity — the tracked-job
    /// list and the streaming-session set. The folding logic lives here so it
    /// can be unit-tested without the service's networking; this service layers
    /// the throttled APNs pushes on top.
    var jobsTracker = JobActivityTracker()
    /// Every job tracked by the single aggregate Live Activity: those still
    /// running plus recently finished ones, in start order.
    var trackedJobs: [JobContent] { jobsTracker.trackedJobs }
    /// Session ids currently streaming — the live job count for the widget.
    var streamingSessionIDs: Set<String> { jobsTracker.streamingSessionIDs }
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
    /// Minimum spacing between aggregate Live Activity update pushes. Coalesces
    /// bursts of job/todo events so APNs's scarce Live Activity budget isn't
    /// exhausted — otherwise the terminal "done" push gets dropped and the
    /// activity stalls on "running".
    static let jobsPushInterval: TimeInterval = 5
    /// When the last aggregate update push actually went out.
    var lastJobsPushDate: Date?
    /// Pending trailing push that flushes coalesced changes at the end of the
    /// throttle window; cancelled if the activity goes away first.
    var pendingJobsPushTask: Task<Void, Never>?
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
        loadSavedRelayServers()
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
            // Start all enabled relay servers
            for server in savedRelayServers where server.isEnabled {
                await startRelayServer(server)
            }

            // If no saved servers, we have nothing to connect to
            if savedRelayServers.isEmpty {
                logger.info("[MobileSync] no relay servers configured — waiting for user to add one")
            }
        }
    }

    /// Start connection to a specific relay server.
    func startRelayServer(_ server: SavedRelayServer) async {
        guard let url = URL(string: server.url) else {
            logger.error("[MobileSync] invalid relay URL for server=\(server.name, privacy: .public)")
            return
        }

        // Check if already connected
        if additionalClients[server.id] != nil {
            logger.info("[MobileSync] relay already started server=\(server.name, privacy: .public)")
            return
        }

        logger.info("[MobileSync] starting relay server=\(server.name, privacy: .public) url=\(server.url, privacy: .public) desktopKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")

        let newClient = SyncClient(identity: identity, relayURL: url)
        additionalClients[server.id] = newClient

        // Add all paired devices that use this relay
        for device in pairedDevices where Self.normalize(device.relayURL ?? "") == Self.normalize(server.url) {
            do {
                try await newClient.addPeer(device.pubkeyHex)
                logger.info("[MobileSync] added paired peer mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) to relay=\(server.name, privacy: .public)")
            } catch {
                logger.error("[MobileSync] failed to add paired peer mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Subscribe to events
        let events = await newClient.events()
        additionalEventTasks[server.id]?.cancel()
        additionalEventTasks[server.id] = Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event: event, forServer: server)
            }
        }

        await newClient.start()
    }

    /// Stop connection to a specific relay server.
    func stopRelayServer(_ server: SavedRelayServer) async {
        additionalEventTasks[server.id]?.cancel()
        additionalEventTasks.removeValue(forKey: server.id)

        if let client = additionalClients.removeValue(forKey: server.id) {
            await client.stop()
            logger.info("[MobileSync] stopped relay server=\(server.name, privacy: .public)")
        }

        relayConnectionStates.removeValue(forKey: server.id)
    }

    /// Normalize a URL string for comparison.
    static func normalize(_ urlString: String) -> String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Find the SyncClient that handles a device based on its relay URL.
    func clientForDevice(_ device: PairedDevice) -> SyncClient? {
        guard let deviceRelayURL = device.relayURL else { return nil }
        let normalizedDeviceURL = Self.normalize(deviceRelayURL)
        for server in savedRelayServers {
            if Self.normalize(server.url) == normalizedDeviceURL {
                return additionalClients[server.id]
            }
        }
        return nil
    }

    /// Find the SyncClient that should be used for a paired mobile key.
    ///
    /// Multirelay connections keep one client per relay server. Replies must
    /// go back through the relay used by the paired device, not the legacy
    /// single-relay client, otherwise request/response flows time out.
    func clientForPeer(_ pubkeyHex: String) -> SyncClient {
        guard let device = pairedDevices.first(where: { $0.pubkeyHex == pubkeyHex }),
              let deviceClient = clientForDevice(device)
        else {
            return client
        }
        return deviceClient
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        pendingJobsPushTask?.cancel()
        pendingJobsPushTask = nil

        // Stop all relay server connections
        for (serverID, task) in additionalEventTasks {
            task.cancel()
            additionalEventTasks.removeValue(forKey: serverID)
        }
        Task {
            for (serverID, client) in additionalClients {
                await client.stop()
                additionalClients.removeValue(forKey: serverID)
            }
        }
        relayConnectionStates.removeAll()
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
    /// - Parameter server: The relay server to pair through. If nil, uses the first enabled server.
    func beginPairing(viaServer server: SavedRelayServer? = nil) -> PairingToken? {
        let targetServer = server ?? savedRelayServers.first(where: { $0.isEnabled })
        guard let targetServer else {
            logger.warning("[Pairing] no relay server available for pairing")
            return nil
        }

        pairingRelayServerID = targetServer.id
        let token = PairingToken(
            relayURL: targetServer.url,
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

        // Get the relay server and client used for this pairing
        let pairingServer = pairingRelayServerID.flatMap { id in savedRelayServers.first { $0.id == id } }
        let pairingClient = pairingRelayServerID.flatMap { additionalClients[$0] }
        let relayURLString = pairingServer?.url ?? pairingToken?.relayURL ?? ""

        let device = PairedDevice(
            pubkeyHex: pending.mobilePubkeyHex,
            displayName: pending.displayName,
            platform: pending.platform,
            apnsToken: nil,
            apnsEnvironment: Self.normalizedAPNSEnvironment(pending.apnsEnvironment),
            pairedAt: .now,
            lastSeen: .now,
            relayURL: relayURLString
        )
        pairedDevices.removeAll { $0.pubkeyHex == device.pubkeyHex }
        pairedDevices.append(device)
        savePairedDevices()

        if let pairingClient {
            try? await pairingClient.addPeer(device.pubkeyHex)
            let ack = PairAckPayload(accepted: true, desktopName: localDeviceName)
            try? await pairingClient.send(.pairAck(ack), toHex: device.pubkeyHex)
        }

        isPairing = false
        pendingPairing = nil
        pairingToken = nil
        pairingRelayServerID = nil
        pairingContinuation?.resume(returning: .accepted(device))
        pairingContinuation = nil
        logger.info("[Pairing] accepted mobile=\(pending.displayName, privacy: .public) mobileKey=\(String(pending.mobilePubkeyHex.prefix(12)), privacy: .public) relay=\(relayURLString, privacy: .public)")
    }

    func cancelPairing() {
        Task {
            if let pending = pendingPairing {
                let pairingClient = pairingRelayServerID.flatMap { additionalClients[$0] }
                if let pairingClient {
                    let ack = PairAckPayload(accepted: false, desktopName: localDeviceName, reason: "rejected")
                    try? await pairingClient.addPeer(pending.mobilePubkeyHex)
                    try? await pairingClient.send(.pairAck(ack), toHex: pending.mobilePubkeyHex)
                    await pairingClient.removePeer(pending.mobilePubkeyHex)
                }
            }
        }
        isPairing = false
        pendingPairing = nil
        pairingToken = nil
        pairingRelayServerID = nil
        pairingContinuation?.resume(returning: .cancelled)
        pairingContinuation = nil
    }

    /// Remove a paired device and notify it before forgetting its pubkey.
    func unpair(_ device: PairedDevice) async {
        let pubkeyHex = device.pubkeyHex

        // Optimistically remove from UI first for immediate feedback
        pairedDevices.removeAll { $0.pubkeyHex == pubkeyHex }
        savePairedDevices()
        subscribedSessions.removeValue(forKey: pubkeyHex)

        // Notify mobile and clean up peer connection (best-effort, ignore failures)
        if let deviceClient = clientForDevice(device) {
            try? await deviceClient.send(.unpair(UnpairPayload(reason: "desktop")), toHex: pubkeyHex)
            await deviceClient.removePeer(pubkeyHex)
        }
    }

    /// Rename a paired device locally.
    func renameDevice(_ device: PairedDevice, to newName: String) {
        guard let index = pairedDevices.firstIndex(where: { $0.pubkeyHex == device.pubkeyHex }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pairedDevices[index].displayName = trimmed
        savePairedDevices()
        logger.info("[MobileSync] renamed device mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) newName=\(trimmed, privacy: .public)")
    }

    // MARK: - Notification fan-out

    /// Broadcast a message to all connected relay clients.
    private func broadcastToAllClients(_ payload: RxCodeSync.Payload) async {
        for client in additionalClients.values {
            await client.broadcast(payload)
        }
    }

    /// Send a notification to every paired device.
    ///
    /// Two delivery paths run for each broadcast:
    /// - the live WebSocket relay channel reaches devices that are currently
    ///   connected and foregrounded;
    /// - a best-effort APNs push reaches devices that are backgrounded or
    ///   offline, so a finished thread still surfaces a banner.
    func broadcastNotification(_ payload: NotificationPayload) {
        Task {
            await broadcastToAllClients(.notification(payload))
            await fanoutAPNs(payload)
        }
    }

    /// Best-effort APNs fan-out: submit one encrypted alert per paired device
    /// that has registered a push token. Per-device failures are logged and
    /// swallowed — the live channel above remains the primary path.
    func fanoutAPNs(_ payload: NotificationPayload) async {
        let devices = pairedDevices.filter { ($0.apnsToken?.isEmpty == false) }
        guard !devices.isEmpty else { return }

        for device in devices {
            // Find the relay URL for this device
            guard let relayURLString = device.relayURL,
                  let relayURL = URL(string: relayURLString),
                  let pushURL = Self.pushEndpointURL(from: relayURL) else {
                logger.error("[APNs] cannot derive push endpoint for device=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                continue
            }
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
        // Find the client for this device's relay
        let deviceClient = clientForDevice(device)
        guard let peer = await deviceClient?.peer(forHex: device.pubkeyHex) else {
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
            collapseID: Self.notificationCollapseID(for: payload, device: device),
            apnsEnvironment: Self.apnsEnvironmentForPush(device)
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
        // Find the client for this device's relay
        let deviceClient = clientForDevice(device)
        guard let peer = await deviceClient?.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }
        guard let relayURLString = device.relayURL,
              let deviceRelayURL = URL(string: relayURLString),
              let pushURL = Self.pushEndpointURL(from: deviceRelayURL) else {
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
            collapseID: Self.testNotificationCollapseID(for: device),
            apnsEnvironment: Self.apnsEnvironmentForPush(device)
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
            await broadcastToAllClients(.sessionUpdate(payload))
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
            await broadcastToAllClients(.questionQueue(QuestionQueuePayload(questions: questions)))
        }
    }

    func broadcastRunTaskUpdate(_ task: MobileRunTaskSnapshot) {
        Task {
            await broadcastToAllClients(.runTaskUpdate(RunTaskUpdatePayload(task: task)))
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

    // MARK: - Saved Relay Servers

    private static let savedRelayServersKey = "mobileSync.savedRelayServers"

    func loadSavedRelayServers() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedRelayServersKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        savedRelayServers = (try? decoder.decode([SavedRelayServer].self, from: data)) ?? []
    }

    func saveSavedRelayServers() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(savedRelayServers)
            UserDefaults.standard.set(data, forKey: Self.savedRelayServersKey)
        } catch {
            logger.error("save relay servers: \(error.localizedDescription)")
        }
    }

    func addRelayServer(_ server: SavedRelayServer) {
        // Avoid duplicates by URL
        let normalizedURL = server.url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if savedRelayServers.contains(where: {
            $0.url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedURL
        }) {
            return
        }
        savedRelayServers.append(server)
        saveSavedRelayServers()
        logger.info("[MobileSync] added relay server name=\(server.name, privacy: .public) url=\(server.url, privacy: .public)")
    }

    func removeRelayServer(_ server: SavedRelayServer) {
        savedRelayServers.removeAll { $0.id == server.id }
        saveSavedRelayServers()
        logger.info("[MobileSync] removed relay server name=\(server.name, privacy: .public)")
    }

    func updateRelayServer(_ server: SavedRelayServer) {
        guard let index = savedRelayServers.firstIndex(where: { $0.id == server.id }) else { return }
        savedRelayServers[index] = server
        saveSavedRelayServers()
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

    func pushEndpointURL(for device: PairedDevice) -> URL? {
        if let relayURLString = device.relayURL, let deviceRelayURL = URL(string: relayURLString) {
            return Self.pushEndpointURL(from: deviceRelayURL)
        }
        return Self.pushEndpointURL(from: relayURL)
    }

    static func apnsEnvironmentForPush(_ device: PairedDevice) -> String? {
        normalizedAPNSEnvironment(device.apnsEnvironment)
    }

    static func normalizedAPNSEnvironment(_ environment: String?) -> String? {
        guard let raw = environment?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty
        else { return nil }

        switch raw {
        case "production", "prod", "release":
            return "production"
        case "sandbox", "development", "dev", "debug":
            return "sandbox"
        default:
            return raw
        }
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
    let apnsEnvironment: String?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case encryptedAlert = "encrypted_alert"
        case category
        case collapseID = "collapse_id"
        case apnsEnvironment = "apns_environment"
    }
}

struct APNsPushResponse: Codable {
    let statusCode: Int
    let reason: String
    let apnsID: String?
    let apnsEnvironment: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case reason
        case apnsID = "apns_id"
        case apnsEnvironment = "apns_environment"
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
    static let mobileSyncRunnableDetectRequested = Notification.Name("mobileSync.runnableDetectRequested")
    static let mobileSyncSkillCatalogRequested = Notification.Name("mobileSync.skillCatalogRequested")
    static let mobileSyncSkillMutationRequested = Notification.Name("mobileSync.skillMutationRequested")
    static let mobileSyncSkillSourceMutationRequested = Notification.Name("mobileSync.skillSourceMutationRequested")
    static let mobileSyncACPRegistryRequested = Notification.Name("mobileSync.acpRegistryRequested")
    static let mobileSyncACPMutationRequested = Notification.Name("mobileSync.acpMutationRequested")
    static let mobileSyncMCPConfigRequested = Notification.Name("mobileSync.mcpConfigRequested")
    static let mobileSyncMCPMutationRequested = Notification.Name("mobileSync.mcpMutationRequested")
}
