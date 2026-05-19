import Foundation

/// Cleartext relay envelope. Everything inside `ct` is opaque to the relay.
public struct Envelope: Codable, Sendable {
    public let v: Int
    public let to: String
    public let from: String
    public let nonce: String
    public let ct: String

    public init(v: Int = 1, to: String, from: String, nonce: Data, ct: Data) {
        self.v = v
        self.to = to
        self.from = from
        self.nonce = nonce.base64EncodedString()
        self.ct = ct.base64EncodedString()
    }

    public var nonceData: Data? { Data(base64Encoded: nonce) }
    public var ciphertextData: Data? { Data(base64Encoded: ct) }
}

/// Sent by the relay back to a sender when the recipient is offline. Useful
/// for desktop to know "skip the live channel, only the APNs push will land".
public struct DeliveryFailedNotice: Codable, Sendable {
    public let v: Int
    public let type: String
    public let to: String
}
