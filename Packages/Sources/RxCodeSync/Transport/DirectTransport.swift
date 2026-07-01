import Foundation
import CryptoKit
import Network
import os

/// A direct TCP `Transport` between two paired devices over `Network.framework`.
///
/// Carries the **identical** `Envelope` JSON the relay carries — same
/// `EnvelopeCodec`, same `SessionCrypto` E2E sealing — so a direct link has the
/// same confidentiality/authenticity guarantee as the relay. The only
/// differences from `RelayClient` are the socket (`NWConnection` vs WebSocket)
/// and framing: raw TCP has no message boundaries, so each envelope is prefixed
/// with a 4-byte big-endian length.
///
/// Peer authentication falls out of the crypto: an envelope from the wrong peer
/// fails `SessionCrypto.open` and is dropped. As defence in depth we also drop
/// any inbound whose `from` doesn't match `expectedPeerHex`.
public actor DirectTransport: Transport {
    /// Frame ceiling mirroring `RelayClient` — reject anything larger as a
    /// malformed/hostile length prefix rather than allocating for it.
    private static let maxFrameSize = 10 * 1024 * 1024
    private static let lengthPrefixBytes = 4

    private let identity: DeviceIdentity
    /// The peer this link is bound to. Known upfront when we dial (`outboundTo`);
    /// `nil` until the first inbound frame when we adopt an accepted connection.
    private var expectedPeerHex: String?
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "DirectTransport")

    private var connection: NWConnection?
    private(set) public var state: TransportConnectionState = .disconnected
    private var continuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]
    private var started = false

    /// The peer hex this link is bound to, once known.
    public var peerHex: String? { expectedPeerHex }

    /// Dial a remote candidate endpoint whose peer identity we already know.
    public init(
        outboundTo endpoint: NWEndpoint,
        identity: DeviceIdentity,
        expectedPeer: Curve25519.KeyAgreement.PublicKey
    ) {
        self.identity = identity
        self.expectedPeerHex = expectedPeer.rawRepresentation.hexString
        self.queue = DispatchQueue(label: "com.idealapp.RxCodeSync.direct.out")
        let params = NWParameters.tcp
        self.connection = NWConnection(to: endpoint, using: params)
    }

    /// Adopt an inbound connection accepted by a `BonjourAdvertiser`'s listener.
    /// The bound peer is learned from the first inbound envelope's cleartext
    /// `from` (the coordinator routes on `peerHex`).
    public init(
        adopting connection: NWConnection,
        identity: DeviceIdentity
    ) {
        self.identity = identity
        self.expectedPeerHex = nil
        self.queue = DispatchQueue(label: "com.idealapp.RxCodeSync.direct.in")
        self.connection = connection
    }

    // MARK: - Transport

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func connect() {
        guard let connection, !started else { return }
        started = true
        updateState(.connecting)
        connection.stateUpdateHandler = { [weak self] newState in
            Task { await self?.handleConnectionState(newState) }
        }
        connection.start(queue: queue)
    }

    public func disconnect() {
        started = false
        connection?.cancel()
        connection = nil
        if state != .disconnected { updateState(.disconnected) }
        finishContinuations()
    }

    public func send(_ payload: Payload, to recipient: Curve25519.KeyAgreement.PublicKey) async throws {
        guard let connection, state == .connected else { throw RelayError.notConnected }
        let body = try EnvelopeCodec.encode(payload, from: identity, to: recipient)
        guard body.count <= Self.maxFrameSize else { throw DirectTransportError.frameTooLarge }
        var frame = Data(count: Self.lengthPrefixBytes)
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { frame.replaceSubrange(0..<Self.lengthPrefixBytes, with: $0) }
        frame.append(body)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    // MARK: - Private

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }

    private func emit(_ event: TransportEvent) {
        for c in continuations.values { c.yield(event) }
    }

    private func updateState(_ newState: TransportConnectionState) {
        state = newState
        emit(.stateChanged(newState))
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            logger.info("[Direct] connection ready peer=\(String((self.expectedPeerHex ?? "pending").prefix(12)), privacy: .public)")
            updateState(.connected)
            receiveNextFrame()
        case .failed(let error), .waiting(let error):
            logger.error("[Direct] connection failed peer=\(String((self.expectedPeerHex ?? "pending").prefix(12)), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            teardown()
        case .cancelled:
            teardown()
        default:
            break
        }
    }

    private func teardown() {
        guard state != .disconnected else { return }
        started = false
        connection?.cancel()
        connection = nil
        updateState(.disconnected)
        // Finish the event stream so the hub's per-connection pump loop exits
        // and stops retaining this transport — otherwise every dropped/failed
        // direct link would leak a Task and a zombie NWConnection wrapper.
        finishContinuations()
    }

    private func finishContinuations() {
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    /// Read a 4-byte length, then that many bytes, then loop.
    private func receiveNextFrame() {
        guard let connection else { return }
        connection.receive(
            minimumIncompleteLength: Self.lengthPrefixBytes,
            maximumLength: Self.lengthPrefixBytes
        ) { [weak self] data, _, isComplete, error in
            Task { await self?.handleLengthPrefix(data, isComplete: isComplete, error: error) }
        }
    }

    private func handleLengthPrefix(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            logger.error("[Direct] receive length failed error=\(error.localizedDescription, privacy: .public)")
            teardown(); return
        }
        guard let data, data.count == Self.lengthPrefixBytes else {
            if isComplete { teardown() }
            return
        }
        let length = data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, Int(length) <= Self.maxFrameSize else {
            logger.error("[Direct] rejecting frame length=\(length, privacy: .public)")
            teardown(); return
        }
        receiveBody(length: Int(length))
    }

    private func receiveBody(length: Int) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            Task { await self?.handleBody(data, isComplete: isComplete, error: error) }
        }
    }

    private func handleBody(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            logger.error("[Direct] receive body failed error=\(error.localizedDescription, privacy: .public)")
            teardown(); return
        }
        if let data {
            switch EnvelopeCodec.decode(data, localIdentity: identity) {
            case .inbound(let inbound):
                if let bound = expectedPeerHex {
                    // Defence in depth: only accept the peer this link is for.
                    if inbound.fromHex == bound {
                        emit(.inbound(inbound))
                    } else {
                        logger.warning("[Direct] dropping inbound from unexpected peer=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                    }
                } else {
                    // Adopted inbound: bind to the peer that authenticated first.
                    expectedPeerHex = inbound.fromHex
                    logger.info("[Direct] adopted link bound to peer=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                    emit(.inbound(inbound))
                }
            case .deliveryFailed, .drop:
                break
            }
        }
        if isComplete { teardown(); return }
        receiveNextFrame()
    }
}

public enum DirectTransportError: Error, Sendable {
    case frameTooLarge
}
