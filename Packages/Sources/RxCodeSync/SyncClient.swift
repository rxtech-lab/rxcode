import Foundation
import CryptoKit

/// High-level facade used by both the desktop service and the iOS app.
///
/// Owns a `RelayClient` and translates app-level intents ("send this user
/// message", "respond to permission request") into encrypted envelopes
/// addressed to a paired peer.
public actor SyncClient {
    public let identity: DeviceIdentity
    public let relayURL: URL
    private let relay: RelayClient

    /// Map of paired peer pubkey-hex to their `Curve25519` public key.
    /// Desktop usually has 1..n entries (one per paired mobile); mobile has 1
    /// (the paired desktop).
    private var peers: [String: Curve25519.KeyAgreement.PublicKey] = [:]

    public init(identity: DeviceIdentity, relayURL: URL) {
        self.identity = identity
        self.relayURL = relayURL
        self.relay = RelayClient(identity: identity, relayURL: relayURL)
    }

    public func start() async {
        await relay.connect()
    }

    public func stop() async {
        await relay.disconnect()
    }

    public func events() async -> AsyncStream<RelayClient.Event> {
        await relay.events()
    }

    public func addPeer(_ pubkeyHex: String) throws {
        guard let raw = Data(hexString: pubkeyHex) else { throw SyncError.invalidPubkey }
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        peers[pubkeyHex] = key
    }

    public func removePeer(_ pubkeyHex: String) {
        peers.removeValue(forKey: pubkeyHex)
    }

    public func peer(forHex hex: String) -> Curve25519.KeyAgreement.PublicKey? {
        peers[hex]
    }

    /// Send `payload` to a single paired peer.
    public func send(_ payload: Payload, toHex hex: String) async throws {
        guard let key = peers[hex] else { throw SyncError.unknownPeer }
        try await relay.send(payload, to: key)
    }

    /// Broadcast `payload` to every paired peer (e.g. notification fan-out).
    public func broadcast(_ payload: Payload) async {
        for (_, key) in peers {
            try? await relay.send(payload, to: key)
        }
    }
}

public enum SyncError: Error, Sendable {
    case unknownPeer
    case invalidPubkey
}
