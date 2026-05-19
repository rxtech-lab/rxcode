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

    /// Remove a paired device. The mobile loses access immediately on the
    /// next message — desktop simply forgets its pubkey.
    func unpair(_ device: PairedDevice) async {
        pairedDevices.removeAll { $0.pubkeyHex == device.pubkeyHex }
        savePairedDevices()
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

    // MARK: - Streaming hooks

    /// Called by AppState's streaming loop after each StreamEvent is folded
    /// into local state.
    func broadcastSessionUpdate(sessionID: String, kind: SessionUpdatePayload.Kind, message: ChatMessage?, isStreaming: Bool?) {
        Task {
            let payload = SessionUpdatePayload(
                sessionID: sessionID,
                kind: kind,
                message: message,
                isStreaming: isStreaming
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
        case .apnsToken(let t):
            if let idx = pairedDevices.firstIndex(where: { $0.pubkeyHex == inbound.fromHex }) {
                pairedDevices[idx].apnsToken = t.tokenHex
                pairedDevices[idx].apnsEnvironment = t.environment
                pairedDevices[idx].lastSeen = .now
                savePairedDevices()
            }
        case .requestSnapshot:
            // AppState owns the data; it observes pendingSnapshotRequests
            // and replies. Stub for now — wired up by AppState bridge.
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex]
            )
        case .userMessage(let msg):
            NotificationCenter.default.post(
                name: .mobileSyncUserMessageReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": msg]
            )
        case .newSessionRequest(let req):
            NotificationCenter.default.post(
                name: .mobileSyncNewSessionRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .subscribeSession(let sub):
            subscribedSessions[inbound.fromHex] = sub.sessionID ?? ""
        case .permissionResponse(let resp):
            NotificationCenter.default.post(
                name: .mobileSyncPermissionResponse,
                object: nil,
                userInfo: ["payload": resp]
            )
        case .ping:
            Task { try? await client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
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
}

extension Notification.Name {
    static let mobileSyncSnapshotRequested = Notification.Name("mobileSync.snapshotRequested")
    static let mobileSyncUserMessageReceived = Notification.Name("mobileSync.userMessageReceived")
    static let mobileSyncNewSessionRequested = Notification.Name("mobileSync.newSessionRequested")
    static let mobileSyncPermissionResponse = Notification.Name("mobileSync.permissionResponse")
}
