import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

/// One paired mobile device. Persisted to
/// `~/Library/Application Support/RxCode/paired_devices.json`.
struct PairedDevice: Codable, Identifiable, Sendable, Hashable {
    var pubkeyHex: String
    var displayName: String
    var platform: String
    var apnsToken: String?
    var apnsEnvironment: String?
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

    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var connectionState: RelayClient.ConnectionState = .disconnected
    @Published private(set) var isPairing: Bool = false
    @Published private(set) var pendingPairing: PairRequestPayload?
    @Published var relayURL: URL

    private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
    private let identity: DeviceIdentity
    private var client: SyncClient
    private var subscribedSessions: [String: String] = [:]
    private var eventTask: Task<Void, Never>?
    private var pairingToken: PairingToken?
    private var pairingContinuation: CheckedContinuation<PairingOutcome, Never>?

    /// The single AppState reference is set in init order from RxCodeApp,
    /// because AppState owns the storage layer and the streaming loop.
    private weak var appState: AnyObject?

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

    private static func logFatalKeychain(_ error: Error) {
        Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
            .fault("device-identity load failed: \(String(describing: error))")
    }

    // MARK: - Public API

    var localPublicKeyHex: String { identity.publicKeyHex }
    var localDeviceName: String { Host.current().localizedName ?? "Mac" }

    /// Begin (or resume) the relay connection. Safe to call multiple times.
    func start() {
        Task { @MainActor in
            for device in pairedDevices {
                try? await client.addPeer(device.pubkeyHex)
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
    func broadcastNotification(_ payload: NotificationPayload) {
        Task {
            await client.broadcast(.notification(payload))
            // Best-effort APNs path is intentionally not yet wired here — the
            // /push endpoint in the relay server provides it; a follow-up
            // patch will submit encrypted alerts for each paired device that
            // has an APNs token. See PLAN risk areas.
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
        summary: RxCodeSync.SessionSummary? = nil,
        previousSessionID: String? = nil
    ) {
        Task {
            let payload = SessionUpdatePayload(
                sessionID: sessionID,
                kind: kind,
                message: message,
                isStreaming: isStreaming,
                summary: summary,
                previousSessionID: previousSessionID
            )
            await client.broadcast(.sessionUpdate(payload))
        }
    }

    // MARK: - Event dispatch

    private func handle(event: RelayClient.Event) {
        switch event {
        case .stateChanged(let s):
            connectionState = s
        case .deliveryFailed:
            // Drop-on-offline policy — desktop ignores, mobile will resync on
            // next reconnect.
            break
        case .inbound(let inbound):
            handleInbound(inbound)
        }
    }

    private func handleInbound(_ inbound: RelayClient.Inbound) {
        switch inbound.payload {
        case .pairRequest(let req):
            pendingPairing = req
            Task { try? await client.addPeer(req.mobilePubkeyHex) }
        case .unpair:
            guard isPairedPeer(inbound.fromHex) else { return }
            handleRemoteUnpair(pubkeyHex: inbound.fromHex)
        case .apnsToken(let t):
            if let idx = pairedDevices.firstIndex(where: { $0.pubkeyHex == inbound.fromHex }) {
                logger.info("[APNs] token received mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public) environment=\(t.environment, privacy: .public)")
                pairedDevices[idx].apnsToken = t.tokenHex
                pairedDevices[idx].apnsEnvironment = t.environment
                pairedDevices[idx].lastSeen = .now
                for staleIdx in pairedDevices.indices where staleIdx != idx && pairedDevices[staleIdx].apnsToken == t.tokenHex {
                    logger.warning("[APNs] clearing duplicate token from stale mobileKey=\(String(self.pairedDevices[staleIdx].pubkeyHex.prefix(12)), privacy: .public) currentMobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public)")
                    pairedDevices[staleIdx].apnsToken = nil
                    pairedDevices[staleIdx].apnsEnvironment = nil
                }
                savePairedDevices()
            } else {
                logger.warning("[APNs] token received for unknown mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public) environment=\(t.environment, privacy: .public)")
            }
        case .requestSnapshot(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "request_snapshot") else { return }
            // AppState owns the data; it observes pendingSnapshotRequests
            // and replies. Stub for now — wired up by AppState bridge.
            var userInfo: [String: Any] = ["from": inbound.fromHex]
            userInfo["activeSessionID"] = req.activeSessionID
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: userInfo
            )
        case .settingsUpdate(let update):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "settings_update") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncSettingsUpdateReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": update]
            )
        case .userMessage(let msg):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "user_message") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncUserMessageReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": msg]
            )
        case .newSessionRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "new_session_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncNewSessionRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .subscribeSession(let sub):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "subscribe_session") else { return }
            subscribedSessions[inbound.fromHex] = sub.sessionID ?? ""
            var userInfo: [String: Any] = ["from": inbound.fromHex]
            userInfo["activeSessionID"] = sub.sessionID
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: userInfo
            )
        case .permissionResponse(let resp):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "permission_response") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncPermissionResponse,
                object: nil,
                userInfo: ["payload": resp]
            )
        case .ping:
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "ping") else { return }
            Task { try? await client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

    private func isPairedPeer(_ pubkeyHex: String) -> Bool {
        pairedDevices.contains { $0.pubkeyHex == pubkeyHex }
    }

    private func acceptPairedOnlyPayload(from pubkeyHex: String, type: String) -> Bool {
        guard isPairedPeer(pubkeyHex) else {
            logger.warning("[MobileSync] rejecting \(type, privacy: .public) from unknown mobileKey=\(String(pubkeyHex.prefix(12)), privacy: .public)")
            Task {
                try? await client.addPeer(pubkeyHex)
                try? await client.send(.unpair(UnpairPayload(reason: "unknown_peer")), toHex: pubkeyHex)
                await client.removePeer(pubkeyHex)
            }
            return false
        }
        return true
    }

    private func handleRemoteUnpair(pubkeyHex: String) {
        guard pairedDevices.contains(where: { $0.pubkeyHex == pubkeyHex }) else {
            Task { await client.removePeer(pubkeyHex) }
            return
        }

        pairedDevices.removeAll { $0.pubkeyHex == pubkeyHex }
        savePairedDevices()
        subscribedSessions.removeValue(forKey: pubkeyHex)
        logger.info("[MobileSync] removed paired device after remote unpair")
        Task { await client.removePeer(pubkeyHex) }
    }

    /// Send a payload to a single peer (used by AppState when replying to
    /// `request_snapshot` etc).
    func send(_ payload: Payload, toHex hex: String) async {
        try? await client.send(payload, toHex: hex)
    }

    // MARK: - Persistence

    private var pairedDevicesURL: URL {
        AppSupport.bundleScopedURL.appendingPathComponent("paired_devices.json")
    }

    private func loadPairedDevices() {
        guard let data = try? Data(contentsOf: pairedDevicesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        pairedDevices = (try? decoder.decode([PairedDevice].self, from: data)) ?? []
    }

    private func savePairedDevices() {
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

    private static func pushEndpointURL(from relayURL: URL) -> URL? {
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

    private static func responseBodyString(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Empty response" : raw
    }

    private static func testNotificationCollapseID(for device: PairedDevice) -> String {
        "rxcode-test-\(device.pubkeyHex.prefix(32))"
    }
}

private struct APNsPushRequest: Codable {
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

private struct APNsPushResponse: Codable {
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
    static let mobileSyncNewSessionRequested = Notification.Name("mobileSync.newSessionRequested")
    static let mobileSyncSettingsUpdateReceived = Notification.Name("mobileSync.settingsUpdateReceived")
    static let mobileSyncPermissionResponse = Notification.Name("mobileSync.permissionResponse")
}
