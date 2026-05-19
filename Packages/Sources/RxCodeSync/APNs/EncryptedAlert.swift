import Foundation
import CryptoKit

/// On-the-wire shape of the alert blob nested under `enc` in the APNs payload.
///
/// The same `SessionCrypto.seal/open` primitive used for relay envelopes is
/// reused here, so the iOS Notification Service Extension only needs the
/// device's long-term Curve25519 private key plus the sender's pubkey to
/// decrypt and present the visible alert.
public struct EncryptedAlert: Codable, Sendable {
    public let v: Int
    public let from: String
    public let nonce: String
    public let ct: String

    public init(v: Int = 1, from: String, nonce: Data, ct: Data) {
        self.v = v
        self.from = from
        self.nonce = nonce.base64EncodedString()
        self.ct = ct.base64EncodedString()
    }

    public var nonceData: Data? { Data(base64Encoded: nonce) }
    public var ciphertextData: Data? { Data(base64Encoded: ct) }
}

/// Plaintext shape of the decrypted alert. The NSE rewrites the visible
/// `aps.alert.title` and `aps.alert.body` from these fields.
public struct AlertPlaintext: Codable, Sendable {
    public let title: String
    public let body: String
    public let sessionID: String?
    public let projectID: UUID?
    public let kind: String?

    public init(
        title: String,
        body: String,
        sessionID: String? = nil,
        projectID: UUID? = nil,
        kind: String? = nil
    ) {
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.projectID = projectID
        self.kind = kind
    }
}

public enum APNsCrypto {
    /// Desktop side: seal an alert for a paired mobile.
    public static func seal(
        plaintext: AlertPlaintext,
        sender: Curve25519.KeyAgreement.PrivateKey,
        recipient: Curve25519.KeyAgreement.PublicKey
    ) throws -> EncryptedAlert {
        let data = try JSONEncoder().encode(plaintext)
        let (nonce, ct) = try SessionCrypto.seal(plaintext: data, sender: sender, recipient: recipient)
        return EncryptedAlert(from: sender.publicKey.rawRepresentation.hexString, nonce: nonce, ct: ct)
    }

    /// NSE side: open a sealed alert. The `from` field tells the NSE which
    /// stored peer pubkey to use as the sender.
    public static func open(
        envelope: EncryptedAlert,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        sender: Curve25519.KeyAgreement.PublicKey
    ) throws -> AlertPlaintext {
        guard let nonce = envelope.nonceData, let ct = envelope.ciphertextData else {
            throw SessionCrypto.CryptoError.openFailed
        }
        let raw = try SessionCrypto.open(
            ciphertext: ct,
            nonce: nonce,
            recipient: recipient,
            sender: sender
        )
        return try JSONDecoder().decode(AlertPlaintext.self, from: raw)
    }
}
