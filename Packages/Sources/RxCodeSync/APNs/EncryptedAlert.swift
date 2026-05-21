import Foundation
import CryptoKit

/// On-the-wire shape of a sealed APNs blob.
///
/// Carried under `enc` for visible alerts and under `encWidget` for silent
/// home-screen widget refreshes. The envelope is content-agnostic — it only
/// holds the sender pubkey, nonce, and ciphertext, never the plaintext shape.
///
/// The same `SessionCrypto.seal/open` primitive used for relay envelopes is
/// reused here, so the recipient only needs the device's long-term Curve25519
/// private key plus the sender's pubkey to decrypt the payload.
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

/// Plaintext shape of a sealed home-screen widget snapshot, mirroring the
/// fields the desktop pushes for `RxCodeWidgetData`. Every field except
/// `updatedAt` is optional so a usage-only or job-count-only push still merges
/// cleanly into the device's stored snapshot.
public struct WidgetSnapshotPayload: Codable, Sendable {
    /// Number of in-progress jobs, or `nil` to leave the stored value untouched.
    public let jobs: Int?
    /// Claude Code 5-hour utilization (0...100), or `nil` to leave untouched.
    public let cc: Double?
    /// Codex 5-hour utilization (0...100), or `nil` to leave untouched.
    public let codex: Double?
    /// When the desktop produced this snapshot, unix seconds.
    public let updatedAt: Double

    public init(jobs: Int? = nil, cc: Double? = nil, codex: Double? = nil, updatedAt: Double) {
        self.jobs = jobs
        self.cc = cc
        self.codex = codex
        self.updatedAt = updatedAt
    }
}

public enum APNsCrypto {
    /// Seal any `Encodable` value into the content-agnostic `EncryptedAlert`
    /// envelope. Backs both the alert and widget paths below.
    public static func sealValue<T: Encodable>(
        _ value: T,
        sender: Curve25519.KeyAgreement.PrivateKey,
        recipient: Curve25519.KeyAgreement.PublicKey
    ) throws -> EncryptedAlert {
        let data = try JSONEncoder().encode(value)
        let (nonce, ct) = try SessionCrypto.seal(plaintext: data, sender: sender, recipient: recipient)
        return EncryptedAlert(from: sender.publicKey.rawRepresentation.hexString, nonce: nonce, ct: ct)
    }

    /// Open an `EncryptedAlert` envelope into a value of the requested type.
    /// The `from` field tells the recipient which peer pubkey is the sender.
    public static func openValue<T: Decodable>(
        _ type: T.Type,
        envelope: EncryptedAlert,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        sender: Curve25519.KeyAgreement.PublicKey
    ) throws -> T {
        guard let nonce = envelope.nonceData, let ct = envelope.ciphertextData else {
            throw SessionCrypto.CryptoError.openFailed
        }
        let raw = try SessionCrypto.open(
            ciphertext: ct,
            nonce: nonce,
            recipient: recipient,
            sender: sender
        )
        return try JSONDecoder().decode(T.self, from: raw)
    }

    /// Desktop side: seal an alert for a paired mobile.
    public static func seal(
        plaintext: AlertPlaintext,
        sender: Curve25519.KeyAgreement.PrivateKey,
        recipient: Curve25519.KeyAgreement.PublicKey
    ) throws -> EncryptedAlert {
        try sealValue(plaintext, sender: sender, recipient: recipient)
    }

    /// NSE side: open a sealed alert. The `from` field tells the NSE which
    /// stored peer pubkey to use as the sender.
    public static func open(
        envelope: EncryptedAlert,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        sender: Curve25519.KeyAgreement.PublicKey
    ) throws -> AlertPlaintext {
        try openValue(AlertPlaintext.self, envelope: envelope, recipient: recipient, sender: sender)
    }

    /// Desktop side: seal a widget snapshot for a paired mobile.
    public static func sealWidget(
        _ snapshot: WidgetSnapshotPayload,
        sender: Curve25519.KeyAgreement.PrivateKey,
        recipient: Curve25519.KeyAgreement.PublicKey
    ) throws -> EncryptedAlert {
        try sealValue(snapshot, sender: sender, recipient: recipient)
    }

    /// App side: open a sealed widget snapshot in the background-push handler.
    public static func openWidget(
        envelope: EncryptedAlert,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        sender: Curve25519.KeyAgreement.PublicKey
    ) throws -> WidgetSnapshotPayload {
        try openValue(WidgetSnapshotPayload.self, envelope: envelope, recipient: recipient, sender: sender)
    }
}
