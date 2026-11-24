import CryptoKit
import Foundation

public enum ExtensionVerificationError: String, LocalizedError, Sendable {
    case unsupportedFormat = "Unsupported extension signature format."
    case invalidPayload = "Invalid extension signature payload."
    case unknownKey = "This signing key is unknown."
    case badSignature = "The signature is invalid."
    case digestMismatch = "The archive digest does not match the signed digest."
    case codeHashMismatch = "The code directory hash does not match the signed hash."
    case revoked = "Extension blocked · update required."
    case staleSequence = "The revocation sequence must increase."
    case sizeLimit = "The extension archive exceeds 50 MB."
    case invalidRevocations = "The revocation document is invalid."

    public var errorDescription: String? { rawValue }
}

/// These fields appear at the top level of the detached JSON envelope. The signature covers their
/// canonical UTF-8 representation. JSON field order and whitespace do not affect release signatures.
public struct ExtensionReleaseEnvelope: Codable, Equatable, Sendable {
    public static let supportedFormat = "ed25519-v1"
    public var format: String
    public var keyId: String
    public var id: String
    public var version: String
    public var pluginApi: String
    public var sha256: String
    public var cdhashes: String
    public var signature: String

    public init(keyId: String, id: String, version: String, pluginApi: String, sha256: String,
                cdhashes: String, signature: String = "", format: String = Self.supportedFormat) {
        self.keyId = keyId
        self.id = id
        self.version = version
        self.pluginApi = pluginApi
        self.sha256 = sha256
        self.cdhashes = cdhashes
        self.signature = signature
        self.format = format
    }

    public func canonicalPayload() throws -> Data {
        guard format == Self.supportedFormat else { throw ExtensionVerificationError.unsupportedFormat }
        let fields = [keyId, id, version, pluginApi, sha256, cdhashes]
        guard fields.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .newlines) == nil }),
              id.range(of: #"\A[a-z0-9]+(?:[.-][a-z0-9-]+)+\z"#, options: .regularExpression) != nil,
              version.range(of: #"\A[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)*\z"#, options: .regularExpression) != nil,
              pluginApi.range(of: #"\A[0-9]+(?:\.[0-9]+)+\z"#, options: .regularExpression) != nil,
              ExtensionReleaseVerifier.isHex(sha256, length: 64) else {
            throw ExtensionVerificationError.invalidPayload
        }
        _ = try architectureHashes()
        return Data((["RxCodeExtension-v1"] + fields).joined(separator: "\n").utf8)
    }

    public func architectureHashes() throws -> [String: String] {
        let components = cdhashes.components(separatedBy: ",")
        let architectures = ["arm64", "x86_64"]
        guard components.count == architectures.count else { throw ExtensionVerificationError.invalidPayload }
        var hashes: [String: String] = [:]
        for (architecture, component) in zip(architectures, components) {
            let pair = component.components(separatedBy: ":")
            guard pair.count == 2, pair[0] == architecture,
                  ExtensionReleaseVerifier.isHex(pair[1], length: 40) else {
                throw ExtensionVerificationError.invalidPayload
            }
            hashes[architecture] = pair[1]
        }
        return hashes
    }

    public func signed(using privateKey: Curve25519.Signing.PrivateKey) throws -> Self {
        var result = self
        result.signature = try privateKey.signature(for: canonicalPayload()).base64EncodedString()
        return result
    }

    /// Repeat at activation using the locally observed hash. No cached metadata or website verdict
    /// can substitute for the signature and the active revocation policy.
    public func verifyActivation(architecture: String, codeHash: String, keys: [String: Data],
                                 revocations: ExtensionRevocations?) throws {
        try verifySignature(keys: keys)
        try revocations?.check(self)
        guard try architectureHashes()[architecture] == codeHash else {
            throw ExtensionVerificationError.codeHashMismatch
        }
    }

    public func verifySignature(keys: [String: Data]) throws {
        let payload = try canonicalPayload()
        guard let bytes = keys[keyId] else { throw ExtensionVerificationError.unknownKey }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes),
              let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: payload) else {
            throw ExtensionVerificationError.badSignature
        }
    }
}

public enum ExtensionReleaseVerifier {
    public static let maximumArchiveBytes = 50 * 1024 * 1024

    public static func digest(_ bytes: Data) -> String {
        hex(SHA256.hash(data: bytes))
    }

    public static func archiveDigest(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var size = 0
        while let bytes = try file.read(upToCount: 256 * 1024), !bytes.isEmpty {
            size += bytes.count
            guard size <= maximumArchiveBytes else { throw ExtensionVerificationError.sizeLimit }
            hash.update(data: bytes)
        }
        return hex(hash.finalize())
    }

    public static func verify(archive: URL, envelope: ExtensionReleaseEnvelope,
                              keys: [String: Data], revocations: ExtensionRevocations?) throws {
        try envelope.verifySignature(keys: keys)
        guard try archiveDigest(at: archive) == envelope.sha256 else {
            throw ExtensionVerificationError.digestMismatch
        }
        try revocations?.check(envelope)
    }

    public static func verifyAllCodeHashes(_ observed: [String: String], envelope: ExtensionReleaseEnvelope) throws {
        guard observed == (try envelope.architectureHashes()) else {
            throw ExtensionVerificationError.codeHashMismatch
        }
    }

    static func isHex(_ string: String, length: Int) -> Bool {
        string.utf8.count == length && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
