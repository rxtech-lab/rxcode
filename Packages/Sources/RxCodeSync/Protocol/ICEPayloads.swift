import Foundation

/// Direct-path (P2P) signaling payloads.
///
/// These are exchanged between two paired devices **over the relay** (the always-
/// warm signaling channel) to negotiate a direct connection, then consumed
/// entirely inside `PeerConnectionManager`. They never reach the app layer — an
/// older peer that predates this feature decodes them as `Payload.unknown` and
/// ignores them, so no version gating is required.

/// A single reachable address a peer offers for a direct connection.
public struct ICECandidate: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Discovered via Bonjour; connect by resolving the service name.
        case lanBonjour
        /// A raw local interface IP:port (mDNS-blocked subnets). Phase 2.
        case lanInterface
        /// A mapped public IP:port obtained via NAT-PMP/PCP. Phase 3.
        case wanMapped
    }

    public let kind: Kind
    /// IP literal for `.lanInterface`/`.wanMapped`; unused for `.lanBonjour`.
    public let host: String
    public let port: Int
    /// Bonjour service instance name, set only for `.lanBonjour`.
    public let bonjourName: String?

    public init(kind: Kind, host: String, port: Int, bonjourName: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.bonjourName = bonjourName
    }
}

/// The set of candidates one peer offers for a given probing round.
public struct ICECandidatesPayload: Codable, Sendable {
    /// Groups a probing round so stale offers can be ignored.
    public let sessionID: UUID
    public let candidates: [ICECandidate]
    /// What the sender believes its own public IP is (Phase 3; nil until then).
    public let observedPublicIP: String?

    public init(sessionID: UUID, candidates: [ICECandidate], observedPublicIP: String? = nil) {
        self.sessionID = sessionID
        self.candidates = candidates
        self.observedPublicIP = observedPublicIP
    }
}

/// Handshake probe/echo sent **over a candidate direct link itself** to confirm
/// it is truly usable (not a half-open NAT that TCP-connects then black-holes)
/// before the coordinator promotes it to the active path.
public struct ICESelectedPayload: Codable, Sendable {
    public let sessionID: UUID
    /// `false` = probe from the initiator; `true` = echo reply from the peer.
    public let echo: Bool

    public init(sessionID: UUID, echo: Bool) {
        self.sessionID = sessionID
        self.echo = echo
    }
}
