import Foundation
import CryptoKit
import Network
import os

/// The hub (SyncClient) provides these services to each per-peer manager: it
/// owns transport creation/pumping and knows this device's local candidates.
public protocol PeerManagerHost: AnyObject, Sendable {
    /// Create, register, pump, and connect an outbound direct link to `endpoint`
    /// on the manager's behalf. Events are routed back via `handleDirectEvent`.
    func dial(_ endpoint: NWEndpoint, priority: Int, pathKind: ConnectionPathKind, for manager: PeerConnectionManager) async
    /// This device's current direct candidates (raw interface IPs + WAN mapping)
    /// to advertise to the peer over the relay.
    func localDirectCandidates() async -> [ICECandidate]
}

/// Per-peer multi-path coordinator.
///
/// Keeps the relay warm as the baseline and races direct candidates — LAN via
/// Bonjour, raw interface IPs, and a mapped WAN port — promoting the first that
/// completes an `.iceSelected` handshake echo. Fails over to the relay instantly
/// if the active direct link drops.
///
/// To avoid two devices each opening a direct link (a wasteful double
/// connection), a deterministic role split applies: the device with the
/// lexicographically smaller pubkey is the **dialer** (it connects); the other
/// **advertises and accepts**. Both still exchange candidates over the relay.
public actor PeerConnectionManager {
    public let peerHex: String
    private let peerKey: Curve25519.KeyAgreement.PublicKey
    private let identity: DeviceIdentity
    private let relay: RelayClient
    private weak var host: PeerManagerHost?
    /// Smaller pubkey dials; the other side only advertises + accepts.
    private let isDialer: Bool
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "PeerConn")

    private var activePath: ConnectionPathKind = .relay
    private var active: DirectTransport?
    private var lastRTTMillis: Int?

    /// In-flight candidate probes, keyed by transport identity.
    private var probing: [ObjectIdentifier: ProbeInfo] = [:]
    private var probeSessionID = UUID()
    /// Endpoints the dialer knows about (from relay candidates + Bonjour), retried
    /// with backoff after a failed round.
    private var knownTargets: [String: DialTarget] = [:]
    private var backoffSeconds = 1
    private var retryTask: Task<Void, Never>?

    private var continuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]

    private struct ProbeInfo {
        let transport: DirectTransport
        let pathKind: ConnectionPathKind
        /// True when we dialed this link (so we send the handshake probe on
        /// connect); false when we adopted an inbound link (we echo instead).
        let initiatedByUs: Bool
        var probeSentAt: Date?
    }
    private struct DialTarget {
        let endpoint: NWEndpoint
        let priority: Int
        let pathKind: ConnectionPathKind
    }

    public init(
        peerHex: String,
        peerKey: Curve25519.KeyAgreement.PublicKey,
        identity: DeviceIdentity,
        relay: RelayClient,
        host: PeerManagerHost
    ) {
        self.peerHex = peerHex
        self.peerKey = peerKey
        self.identity = identity
        self.relay = relay
        self.host = host
        self.isDialer = identity.publicKeyHex < peerHex
    }

    public var currentPath: ConnectionPathKind { activePath }

    /// Disconnect every link and clear connection state. Called when the hub
    /// stops (app backgrounding); the hub then drops this manager and builds a
    /// fresh one on the next start, so we close sockets cleanly rather than
    /// leaking dead `NWConnection`s across a suspend.
    public func teardown() async {
        retryTask?.cancel(); retryTask = nil
        for info in probing.values { await info.transport.disconnect() }
        probing.removeAll()
        await active?.disconnect()
        active = nil
        activePath = .relay
        knownTargets.removeAll()
    }

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Route a payload over the active path, falling back to relay on failure.
    public func send(_ payload: Payload) async throws {
        if activePath != .relay, let active {
            do {
                try await active.send(payload, to: peerKey)
                return
            } catch {
                logger.error("[PeerConn] direct send failed peer=\(String(self.peerHex.prefix(12)), privacy: .public) — failing over to relay")
                demote()
            }
        }
        try await relay.send(payload, to: peerKey)
    }

    // MARK: - Triggers from the hub

    /// Advertise our candidates so the peer can reach us directly. Called when the
    /// relay (re)connects, when this peer is added while already connected, and
    /// when the Bonjour listener binds its port.
    public func offerLocalCandidates() async {
        await offerCandidates()
    }

    /// The network path changed — re-advertise candidates and, if we're on relay,
    /// reset backoff and re-probe known targets.
    public func networkChanged() async {
        await offerCandidates()
        if active == nil {
            backoffSeconds = 1
            dialAllKnownTargets()
        }
    }

    /// A Bonjour endpoint matching this peer was discovered (dialer only).
    public func considerBonjourEndpoint(_ endpoint: NWEndpoint) async {
        guard isDialer, active == nil else { return }
        let key = "bonjour:\(endpoint.debugDescription)"
        knownTargets[key] = DialTarget(endpoint: endpoint, priority: 0, pathKind: .directLAN)
        await dialTarget(knownTargets[key]!)
    }

    /// Relay-delivered ICE signaling.
    ///
    /// LAN candidates are only turned into targets by the LAN **dialer** (smaller
    /// pubkey) so exactly one side opens a LAN link. WAN-mapped candidates are the
    /// exception: only one peer can ever produce one (WAN port mapping is
    /// macOS-only), so whoever *receives* it dials it — this makes a desktop's
    /// reachable `wanMapped` endpoint usable regardless of key order, without
    /// risking a double connection.
    public func handleRelayICE(_ payload: Payload) async {
        guard case .iceCandidates(let offer) = payload, active == nil else { return }
        for candidate in offer.candidates {
            let isWAN = candidate.kind == .wanMapped
            guard isWAN || isDialer else { continue }
            guard let endpoint = Self.endpoint(for: candidate) else { continue }
            let key = "\(candidate.kind.rawValue):\(candidate.host):\(candidate.port)"
            let priority = isWAN ? 2 : 1
            let pathKind: ConnectionPathKind = isWAN ? .directWAN : .directLAN
            knownTargets[key] = DialTarget(endpoint: endpoint, priority: priority, pathKind: pathKind)
        }
        dialAllKnownTargets()
    }

    /// Register a freshly-created outbound probe (called by the hub from `dial`).
    public func registerProbe(_ transport: DirectTransport, pathKind: ConnectionPathKind) {
        guard active == nil else { return }
        probing[ObjectIdentifier(transport)] = ProbeInfo(transport: transport, pathKind: pathKind, initiatedByUs: true, probeSentAt: nil)
    }

    /// Reserve this manager for an adopted inbound link (controlled side).
    public func beginAdoptIfIdle(_ transport: DirectTransport) -> Bool {
        guard active == nil else { return false }
        probing[ObjectIdentifier(transport)] = ProbeInfo(transport: transport, pathKind: .directLAN, initiatedByUs: false, probeSentAt: nil)
        return true
    }

    // MARK: - Direct transport events

    public func handleDirectEvent(_ event: TransportEvent, from transport: DirectTransport) async {
        switch event {
        case .stateChanged(let state):
            await handleDirectState(state, from: transport)
        case .inbound(let inbound):
            await handleDirectInbound(inbound, from: transport)
        case .deliveryFailed, .pathChanged:
            break
        }
    }

    // MARK: - Private

    private func offerCandidates() async {
        guard let host else { return }
        let candidates = await host.localDirectCandidates()
        guard !candidates.isEmpty else { return }
        let payload = Payload.iceCandidates(ICECandidatesPayload(sessionID: probeSessionID, candidates: candidates))
        try? await relay.send(payload, to: peerKey)
    }

    private func dialAllKnownTargets() {
        guard active == nil else { return }
        let targets = knownTargets.values.sorted { $0.priority < $1.priority }
        for target in targets {
            let delay = Double(target.priority) * 0.2  // stagger so LAN wins before WAN is attempted
            Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                await self?.dialTarget(target)
            }
        }
    }

    private func dialTarget(_ target: DialTarget) async {
        guard active == nil, let host else { return }
        // LAN links are opened only by the dialer role; a WAN-mapped endpoint is
        // dialed by whichever side received it (see `handleRelayICE`).
        guard target.pathKind == .directWAN || isDialer else { return }
        await host.dial(target.endpoint, priority: target.priority, pathKind: target.pathKind, for: self)
    }

    private func handleDirectState(_ state: TransportConnectionState, from transport: DirectTransport) async {
        switch state {
        case .connected:
            // Initiator: the moment a probe link we dialed is up, send the probe.
            if let info = probing[ObjectIdentifier(transport)], info.initiatedByUs {
                probing[ObjectIdentifier(transport)]?.probeSentAt = Date()
                try? await transport.send(.iceSelected(ICESelectedPayload(sessionID: probeSessionID, echo: false)), to: peerKey)
            }
        case .disconnected:
            if transport === active {
                logger.warning("[PeerConn] active direct dropped peer=\(String(self.peerHex.prefix(12)), privacy: .public) — reverting to relay")
                demote()
                dialAllKnownTargets()
            } else if probing[ObjectIdentifier(transport)] != nil {
                probing.removeValue(forKey: ObjectIdentifier(transport))
                scheduleRetryIfIdle()
            }
        case .connecting, .reconnecting:
            break
        }
    }

    private func handleDirectInbound(_ inbound: TransportInbound, from transport: DirectTransport) async {
        switch inbound.payload {
        case .iceSelected(let sel):
            if sel.echo {
                // Dialer: our probe was echoed — measure RTT and promote.
                if let info = probing[ObjectIdentifier(transport)] {
                    let rtt = info.probeSentAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                    promote(transport, pathKind: info.pathKind, rttMillis: rtt)
                }
            } else {
                // Controlled side: a probe arrived — echo it back and promote.
                try? await transport.send(.iceSelected(ICESelectedPayload(sessionID: sel.sessionID, echo: true)), to: peerKey)
                if let info = probing[ObjectIdentifier(transport)] {
                    promote(transport, pathKind: info.pathKind, rttMillis: nil)
                }
            }
        case .iceCandidates:
            break
        default:
            if transport === active { emit(.inbound(inbound)) }
        }
    }

    private func promote(_ transport: DirectTransport, pathKind: ConnectionPathKind, rttMillis: Int?) {
        active = transport
        activePath = pathKind
        lastRTTMillis = rttMillis
        backoffSeconds = 1
        retryTask?.cancel(); retryTask = nil
        // Cancel every losing probe.
        let winner = ObjectIdentifier(transport)
        for (oid, info) in probing where oid != winner {
            Task { await info.transport.disconnect() }
        }
        probing.removeAll()
        if let rttMillis {
            logger.info("[PeerConn] promoted \(String(describing: pathKind), privacy: .public) peer=\(String(self.peerHex.prefix(12)), privacy: .public) rtt=\(rttMillis, privacy: .public)ms")
        } else {
            logger.info("[PeerConn] promoted \(String(describing: pathKind), privacy: .public) peer=\(String(self.peerHex.prefix(12)), privacy: .public)")
        }
        emit(.pathChanged(peerHex: peerHex, path: pathKind, rttMillis: rttMillis))
    }

    private func demote() {
        let dropped = active
        active = nil
        activePath = .relay
        lastRTTMillis = nil
        emit(.pathChanged(peerHex: peerHex, path: .relay, rttMillis: nil))
        Task { await dropped?.disconnect() }
    }

    private func scheduleRetryIfIdle() {
        // No `isDialer` gate: a non-dialer may still be retrying a WAN target
        // (the only kind it ever stores). `dialAllKnownTargets` filters per target.
        guard active == nil, probing.isEmpty, retryTask == nil, !knownTargets.isEmpty else { return }
        let delay = backoffSeconds
        backoffSeconds = min(30, backoffSeconds * 2)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self else { return }
            await self.retryNow()
        }
    }

    private func retryNow() {
        retryTask = nil
        guard active == nil else { return }
        probeSessionID = UUID()
        dialAllKnownTargets()
    }

    private static func endpoint(for candidate: ICECandidate) -> NWEndpoint? {
        guard candidate.port > 0, candidate.port <= 65535,
              let port = NWEndpoint.Port(rawValue: UInt16(candidate.port)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(candidate.host), port: port)
    }

    private func emit(_ event: TransportEvent) {
        for c in continuations.values { c.yield(event) }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
}
