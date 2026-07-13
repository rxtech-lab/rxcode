import Foundation
import CryptoKit
import Network
import os

/// High-level facade used by both the desktop service and the iOS app, and the
/// multi-path hub.
///
/// Owns the always-warm `RelayClient` plus, when `directPathsEnabled`, a
/// `PeerConnectionManager` per paired peer, the Bonjour advertiser/browser, an
/// `NWPathMonitor`, and a NAT-PMP `PortMapper`. It is the *sole subscriber* of
/// the relay and every `DirectTransport`, and merges their events into a single
/// upward stream — so `MobileSyncService` / `MobileAppState` keep consuming one
/// `events()` stream exactly as before.
///
/// When `directPathsEnabled == false` the hub is a pure pass-through: `events()`
/// returns the relay's stream and `send` goes straight to the relay, preserving
/// the relay-only behavior byte-for-byte.
public actor SyncClient: PeerManagerHost {
    public let identity: DeviceIdentity
    public let relayURL: URL
    public let directPathsEnabled: Bool
    private let relay: RelayClient
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "SyncClient")

    /// Map of paired peer pubkey-hex to their `Curve25519` public key.
    private var peers: [String: Curve25519.KeyAgreement.PublicKey] = [:]

    // Direct-path state (only populated when `directPathsEnabled`).
    private var managers: [String: PeerConnectionManager] = [:]
    private var advertiser: BonjourAdvertiser?
    private var browser: BonjourBrowser?
    private var pathMonitor: NWPathMonitor?
    private let portMapper = PortMapper()
    private var currentWANMapping: PortMapping?
    private var wanRenewTask: Task<Void, Never>?
    private var hubStarted = false
    private var pumpTasks: [UUID: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<RelayClient.Event>.Continuation] = [:]

    public init(identity: DeviceIdentity, relayURL: URL, directPathsEnabled: Bool = false) {
        self.identity = identity
        self.relayURL = relayURL
        self.directPathsEnabled = directPathsEnabled
        self.relay = RelayClient(identity: identity, relayURL: relayURL)
    }

    public func start() async {
        // `reconnect()` (not `connect()`) so a stale socket left behind by an
        // OS suspend is torn down and reopened. At initial startup `task` is nil,
        // so this behaves exactly like a plain connect.
        await relay.reconnect()
        guard directPathsEnabled else { return }
        startHubIfNeeded()
        // `stop()` cancelled every per-peer event pump and dropped the managers;
        // rebuild them from the persisted peer set so direct-path links — and the
        // inbound data (snapshots, history) they carry — come back after a
        // background cycle. Without this the LAN link re-promotes but its events
        // reach no subscriber, and the app appears connected yet loads nothing.
        for (hex, key) in peers { startManager(forHex: hex, key: key) }
    }

    public func stop() async {
        await relay.disconnect()
        for task in pumpTasks.values { task.cancel() }
        pumpTasks.removeAll()
        wanRenewTask?.cancel(); wanRenewTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
        await advertiser?.stop()
        await browser?.stop()
        // Drop the per-peer managers. Their event pumps were just cancelled and
        // their direct sockets die when the OS suspends us; tearing them down and
        // rebuilding on `start()` avoids reusing a manager stuck with a dead
        // `active` transport (which blocks redial and silently swallows data).
        for manager in managers.values { await manager.teardown() }
        managers.removeAll()
        hubStarted = false
    }

    public func events() async -> AsyncStream<RelayClient.Event> {
        guard directPathsEnabled else { return await relay.events() }
        return AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func addPeer(_ pubkeyHex: String) throws {
        guard let raw = Data(hexString: pubkeyHex) else { throw SyncError.invalidPubkey }
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        peers[pubkeyHex] = key
        startManager(forHex: pubkeyHex, key: key)
    }

    /// Create the per-peer manager and its event pump, unless direct paths are
    /// disabled or one is already running. Idempotent: called both when a peer is
    /// added and when `start()` rebuilds managers after a background cycle.
    private func startManager(forHex pubkeyHex: String, key: Curve25519.KeyAgreement.PublicKey) {
        guard directPathsEnabled, managers[pubkeyHex] == nil else { return }
        let manager = PeerConnectionManager(peerHex: pubkeyHex, peerKey: key, identity: identity, relay: relay, host: self)
        managers[pubkeyHex] = manager
        track { [weak self] in
            let stream = await manager.events()
            for await event in stream { await self?.emitUp(event) }
        }
        // A peer added while the relay is already connected (e.g. right after
        // pairing, or on a foreground rebuild) would otherwise miss the
        // `.stateChanged(.connected)` that triggers the first candidate offer.
        // Offer immediately in that case.
        track { [weak self, weak manager] in
            guard let self, let manager else { return }
            if await self.relayIsConnected { await manager.offerLocalCandidates() }
        }
    }

    private var relayIsConnected: Bool {
        get async { await relay.state == .connected }
    }

    public func removePeer(_ pubkeyHex: String) {
        peers.removeValue(forKey: pubkeyHex)
        managers.removeValue(forKey: pubkeyHex)
    }

    public func peer(forHex hex: String) -> Curve25519.KeyAgreement.PublicKey? { peers[hex] }

    /// Send `payload` to a single paired peer over its best available path.
    public func send(_ payload: Payload, toHex hex: String) async throws {
        guard let key = peers[hex] else { throw SyncError.unknownPeer }
        if directPathsEnabled, let manager = managers[hex] {
            try await manager.send(payload)
        } else {
            try await relay.send(payload, to: key)
        }
    }

    /// Broadcast `payload` to every paired peer (e.g. notification fan-out).
    public func broadcast(_ payload: Payload) async {
        for (hex, key) in peers {
            if directPathsEnabled, let manager = managers[hex] {
                try? await manager.send(payload)
            } else {
                try? await relay.send(payload, to: key)
            }
        }
    }

    // MARK: - PeerManagerHost

    public func dial(_ endpoint: NWEndpoint, priority: Int, pathKind: ConnectionPathKind, for manager: PeerConnectionManager) async {
        guard let key = peers[manager.peerHex] else { return }
        let transport = DirectTransport(outboundTo: endpoint, identity: identity, expectedPeer: key)
        await manager.registerProbe(transport, pathKind: pathKind)
        track { [weak manager] in
            let stream = await transport.events()
            for await event in stream { await manager?.handleDirectEvent(event, from: transport) }
        }
        await transport.connect()
    }

    public func localDirectCandidates() async -> [ICECandidate] {
        guard let port = await advertiser?.listeningPort() else { return [] }
        var candidates: [ICECandidate] = []
        for ip in NetworkInterfaces.localIPAddresses() {
            candidates.append(ICECandidate(kind: .lanInterface, host: ip, port: Int(port)))
        }
        if let wan = currentWANMapping {
            candidates.append(ICECandidate(kind: .wanMapped, host: wan.publicIP, port: Int(wan.externalPort)))
        }
        return candidates
    }

    // MARK: - Hub plumbing

    private func startHubIfNeeded() {
        guard !hubStarted else { return }
        hubStarted = true

        // 1. Relay pump: intercept ICE signaling, forward everything else up, and
        //    trigger candidate offers when the relay (re)connects.
        track { [weak self] in
            guard let self else { return }
            let stream = await self.relay.events()
            for await event in stream { await self.handleRelayEvent(event) }
        }

        // 2. Bonjour advertise + accept inbound direct links.
        let advertiser = BonjourAdvertiser(localPubkeyHex: identity.publicKeyHex)
        self.advertiser = advertiser
        track { [weak self] in
            let accepted = await advertiser.acceptedConnections()
            await advertiser.start()
            for await connection in accepted { await self?.adoptInbound(connection) }
        }
        // Once the listener binds a port, (re)request the WAN mapping and re-offer
        // candidates — the initial attempt runs before the port exists.
        track { [weak self] in
            let ready = await advertiser.portReady()
            for await _ in ready { await self?.handleListenerReady() }
        }

        // 3. Bonjour browse + dial discovered peers.
        let browser = BonjourBrowser()
        self.browser = browser
        track { [weak self] in
            let discoveries = await browser.discoveries()
            await browser.start()
            for await peer in discoveries { await self?.handleDiscovery(peer) }
        }

        // 4. Watch for network changes to re-gather candidates and re-probe.
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.handlePathChange() }
        }
        monitor.start(queue: DispatchQueue(label: "com.idealapp.RxCodeSync.pathmonitor"))

        // WAN mapping + candidate offers are kicked off from `handleListenerReady`
        // once the Bonjour listener actually binds a port (step 2 above).
    }

    /// The Bonjour listener bound a port: (re)request a WAN mapping and re-offer
    /// candidates to every peer so both interface and WAN candidates propagate.
    private func handleListenerReady() async {
        await refreshWANMapping()
        for manager in managers.values {
            await manager.offerLocalCandidates()
        }
    }

    private func handleRelayEvent(_ event: RelayClient.Event) async {
        switch event {
        case .inbound(let inbound) where Self.isICESignaling(inbound.payload):
            await managers[inbound.fromHex]?.handleRelayICE(inbound.payload)
            return
        case .stateChanged(.connected):
            for manager in managers.values {
                Task { await manager.offerLocalCandidates() }
            }
        default:
            break
        }
        emitUp(event)
    }

    private func handlePathChange() async {
        await refreshWANMapping()
        for manager in managers.values {
            await manager.networkChanged()
        }
    }

    /// Ask the gateway for a public IP:port mapping to our direct listener, then
    /// schedule a renewal before it expires. No mapping ⇒ WAN-direct simply isn't
    /// offered and the relay carries traffic.
    private func refreshWANMapping() async {
        guard !Task.isCancelled else { return }
        guard let port = await advertiser?.listeningPort() else { return }
        guard !Task.isCancelled else { return }
        let mapping = await portMapper.requestMapping(internalPort: port)
        guard !Task.isCancelled else { return }
        currentWANMapping = mapping
        wanRenewTask?.cancel()
        guard let mapping, mapping.lifetimeSeconds > 0 else { return }
        // Renew at half the granted lifetime.
        let renewAfter = max(60, Int(mapping.lifetimeSeconds) / 2)
        wanRenewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(renewAfter) * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refreshWANMapping()
        }
    }

    /// Dial a peer discovered on the LAN.
    private func handleDiscovery(_ peer: DiscoveredDirectPeer) async {
        guard let manager = managers[peer.pubkeyHex] else { return }
        await manager.considerBonjourEndpoint(peer.endpoint)
    }

    /// Adopt an accepted inbound connection, binding it to a peer on the first
    /// authenticated frame (`Envelope.from` is cleartext, so the peer is known
    /// before any plaintext is exposed).
    private func adoptInbound(_ connection: NWConnection) async {
        let transport = DirectTransport(adopting: connection, identity: identity)
        track { [weak self] in
            let stream = await transport.events()
            var bound: PeerConnectionManager?
            for await event in stream {
                if bound == nil, case .inbound(let inbound) = event {
                    guard let manager = await self?.manager(forHex: inbound.fromHex),
                          await manager.beginAdoptIfIdle(transport) else {
                        await transport.disconnect()
                        return
                    }
                    bound = manager
                }
                if let manager = bound {
                    await manager.handleDirectEvent(event, from: transport)
                }
            }
        }
        await transport.connect()
    }

    private func manager(forHex hex: String) -> PeerConnectionManager? { managers[hex] }

    private static func isICESignaling(_ payload: Payload) -> Bool {
        switch payload {
        case .iceCandidates, .iceSelected: return true
        default: return false
        }
    }

    /// Spawn a self-removing pump task so finished direct-link pumps don't
    /// accumulate over reconnect/discovery churn.
    private func track(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let task = Task { [weak self] in
            await body()
            await self?.untrack(id)
        }
        pumpTasks[id] = task
    }

    private func untrack(_ id: UUID) { pumpTasks.removeValue(forKey: id) }

    private func emitUp(_ event: RelayClient.Event) {
        for c in continuations.values { c.yield(event) }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
}

public enum SyncError: Error, Sendable {
    case unknownPeer
    case invalidPubkey
}
