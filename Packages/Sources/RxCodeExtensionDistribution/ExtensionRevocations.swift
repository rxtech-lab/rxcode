import CryptoKit
import Foundation

/// The verifier authenticates the exact response body before decoding it. Keep the signature and
/// original bytes together across launches so the stored baseline can be authenticated again.
public struct ExtensionRevocations: Decodable, Equatable, Sendable {
    public static let supportedFormat = "rxcode-revocations-v1"

    public struct Release: Decodable, Equatable, Sendable {
        public let id: String
        public let version: String
        public let sha256: String
    }

    public let format: String
    public let sequence: Int
    public let issuedAt: String
    public let revokedKeyIds: [String]
    public let revokedReleases: [Release]

    public func check(_ envelope: ExtensionReleaseEnvelope) throws {
        guard !revokedKeyIds.contains(envelope.keyId),
              !revokedReleases.contains(where: {
                  $0.id == envelope.id && $0.version == envelope.version && $0.sha256 == envelope.sha256
              }) else { throw ExtensionVerificationError.revoked }
    }

    public static func verify(rawPayload: Data, signature: String, publicKey: Data,
                              newerThan sequence: Int = 0) throws -> Self {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: rawPayload) else {
            throw ExtensionVerificationError.badSignature
        }
        let document = try decodePayload(rawPayload)
        guard document.sequence > sequence else { throw ExtensionVerificationError.staleSequence }
        return document
    }

    public static func sign(rawPayload: Data, key: Curve25519.Signing.PrivateKey) throws -> String {
        _ = try decodePayload(rawPayload)
        return try key.signature(for: rawPayload).base64EncodedString()
    }

    private static func decodePayload(_ rawPayload: Data) throws -> Self {
        let document = try JSONDecoder().decode(Self.self, from: rawPayload)
        guard document.format == Self.supportedFormat else { throw ExtensionVerificationError.unsupportedFormat }
        let dateWithoutFraction = Date.ISO8601FormatStyle()
        let dateWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard document.sequence > 0,
              (try? dateWithoutFraction.parse(document.issuedAt)) != nil || (try? dateWithFraction.parse(document.issuedAt)) != nil,
              document.revokedKeyIds.allSatisfy({ !$0.isEmpty }),
              document.revokedReleases.allSatisfy({
                  !$0.id.isEmpty && !$0.version.isEmpty && ExtensionReleaseVerifier.isHex($0.sha256, length: 64)
              }) else { throw ExtensionVerificationError.invalidRevocations }
        return document
    }
}
