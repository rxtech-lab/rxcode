import Foundation
import CryptoKit

/// A path over which encrypted `Envelope`s flow between two paired devices.
///
/// Both the relay WebSocket (`RelayClient`) and a direct TCP link
/// (`DirectTransport`) conform. Everything above this seam — `SyncClient`,
/// `MobileSyncService`, `MobileAppState`, and every payload handler — is
/// path-blind: it sends a `Payload` to a peer's public key and receives
/// `TransportEvent`s, regardless of which physical path carries the bytes.
public protocol Transport: Actor {
    /// A multiplexed event stream. Each subscriber gets its own buffered stream.
    func events() -> AsyncStream<TransportEvent>
    /// Begin connecting. Idempotent — a second call while connected is a no-op.
    func connect() async
    /// Tear down and stop reconnecting.
    func disconnect() async
    /// Encrypt `payload` for `recipient` and send the resulting `Envelope`.
    func send(_ payload: Payload, to recipient: Curve25519.KeyAgreement.PublicKey) async throws
}

/// The physical path currently carrying data to a peer. Runtime-only; surfaced
/// in the UI as a badge next to the online indicator.
public enum ConnectionPathKind: String, Sendable, Equatable, Codable {
    case relay
    case directLAN
    case directWAN
}

public enum TransportConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(nextAttemptInSeconds: Int)
}

public struct TransportInbound: Sendable {
    public let from: Curve25519.KeyAgreement.PublicKey
    public let fromHex: String
    public let payload: Payload

    public init(from: Curve25519.KeyAgreement.PublicKey, fromHex: String, payload: Payload) {
        self.from = from
        self.fromHex = fromHex
        self.payload = payload
    }
}

public enum TransportEvent: Sendable {
    case stateChanged(TransportConnectionState)
    case inbound(TransportInbound)
    case deliveryFailed(toHex: String)
    /// Emitted by the multi-path coordinator when the active path to a peer
    /// changes (e.g. relay → direct-LAN, or direct → relay on failover).
    /// `rttMillis` is the measured handshake round-trip when promoting a direct
    /// path, `nil` on relay fallback.
    case pathChanged(peerHex: String, path: ConnectionPathKind, rttMillis: Int?)
}
