import Foundation
import CryptoKit

/// QR-code payload the desktop generates and the mobile scans.
///
/// Encoded as base64-JSON (URL-safe). Carries everything mobile needs to find
/// the relay, encrypt the first envelope, and prove freshness — but contains
/// no long-term mobile secret.
public struct PairingToken: Codable, Sendable {
    public let v: Int
    public let relayURL: String
    public let desktopPubkeyHex: String
    public let sessionID: UUID
    public let oneTimeSecretHex: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let desktopName: String

    public init(
        v: Int = 1,
        relayURL: String,
        desktopPubkeyHex: String,
        sessionID: UUID = UUID(),
        oneTimeSecretHex: String,
        issuedAt: Date = .now,
        expiresAt: Date,
        desktopName: String
    ) {
        self.v = v
        self.relayURL = relayURL
        self.desktopPubkeyHex = desktopPubkeyHex
        self.sessionID = sessionID
        self.oneTimeSecretHex = oneTimeSecretHex
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.desktopName = desktopName
    }

    /// True if `Date.now` is past `expiresAt`. UI should disable scanned tokens
    /// that resolve to `true` and prompt the user to regenerate the QR.
    public var isExpired: Bool { Date.now > expiresAt }

    public var oneTimeSecret: Data? { Data(hexString: oneTimeSecretHex) }

    public var desktopPublicKey: Curve25519.KeyAgreement.PublicKey? {
        guard let raw = Data(hexString: desktopPubkeyHex) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    // MARK: - QR encoding

    public func qrString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return "rxcode-pair:" + data.base64EncodedString(options: .init())
    }

    public static func parse(_ qrString: String) throws -> PairingToken {
        guard qrString.hasPrefix("rxcode-pair:") else { throw PairingError.malformed }
        let b64 = String(qrString.dropFirst("rxcode-pair:".count))
        guard let data = Data(base64Encoded: b64) else { throw PairingError.malformed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PairingToken.self, from: data)
    }

    public static func makeOneTimeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes).hexString
    }
}

public enum PairingError: Error, Sendable {
    case malformed
    case expired
}
