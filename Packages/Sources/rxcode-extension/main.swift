import CryptoKit
import RxCodeExtensionBuild
import Foundation
import RxCodeExtensionDistribution

private let usage = """
Usage: rxcode-extension <command> [options]
  build <directory> --output <path> [--sign <identity>]
  package <bundle> --output <zip> [options]
  keygen
  sign --metadata <json> --key-env <variable> --key-id <id> --output <signature.json>
  verify --archive <zip> --envelope <signature.json> --keys <public-key-map.json>
         [--revocations <json> --revocation-signature <file> --revocation-key <base64>]
  sign-revocation --document <json> --key-env <variable> --output <signature>
  verify-revocation --document <json> --signature <file> --public-key <base64>

Public key maps contain key IDs mapped to base64-encoded raw Ed25519 public keys.
Key generation prints a private key. Run it only in the intended key custody environment.
"""

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Options {
    let values: [String: String]

    init(_ arguments: [String], allowed: Set<String>) throws {
        var options: [String: String] = [:]
        var iterator = arguments.makeIterator()
        while let name = iterator.next() {
            guard allowed.contains(name), options[name] == nil, let value = iterator.next(),
                  !value.hasPrefix("--"), !value.isEmpty else {
                throw CLIError("Invalid or repeated option \(name).\n\(usage)")
            }
            options[name] = value
        }
        values = options
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name] else { throw CLIError("Missing \(name).\n\(usage)") }
        return value
    }

    func url(_ option: String) throws -> URL { URL(fileURLWithPath: try required(option)) }
    func data(_ option: String) throws -> Data { try Data(contentsOf: url(option)) }
    func publicKey(_ option: String) throws -> Data {
        guard let key = Data(base64Encoded: try required(option)), key.count == 32 else {
            throw CLIError("Expected a base64 raw Ed25519 public key for \(option).")
        }
        return key
    }

    func privateKey() throws -> Curve25519.Signing.PrivateKey {
        let name = try required("--key-env")
        guard let value = ProcessInfo.processInfo.environment[name], let data = Data(base64Encoded: value),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw CLIError("Missing or invalid raw Ed25519 private key in \(name).")
        }
        return key
    }

    func signature(_ option: String) throws -> String {
        try String(contentsOf: url(option), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ReleaseMetadata: Decodable {
    let id: String
    let version: String
    let pluginApi: String
    let sha256: String
    let cdhashes: String
}

private func run(_ arguments: [String]) throws {
    guard let command = arguments.first else { throw CLIError(usage) }
    let arguments = Array(arguments.dropFirst())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    switch command {
    case "--help", "-h", "help":
        print(usage)
    case "build", "package":
        try BuildCommands.run(command: command, arguments: arguments)
    case "keygen":
        guard arguments.isEmpty else { throw CLIError(usage) }
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let output = ["privateKey": key.rawRepresentation.base64EncodedString(),
                      "publicKey": publicKey.base64EncodedString(),
                      "keyFingerprint": ExtensionReleaseVerifier.digest(publicKey)]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    case "sign":
        let options = try Options(arguments, allowed: ["--metadata", "--key-env", "--key-id", "--output"])
        let release = try JSONDecoder().decode(ReleaseMetadata.self, from: options.data("--metadata"))
        let envelope = try ExtensionReleaseEnvelope(keyId: options.required("--key-id"), id: release.id,
                                                    version: release.version, pluginApi: release.pluginApi,
                                                    sha256: release.sha256, cdhashes: release.cdhashes)
            .signed(using: options.privateKey())
        try encoder.encode(envelope).write(to: options.url("--output"), options: .atomic)
    case "verify":
        let revocationOptions: Set<String> = ["--revocations", "--revocation-signature", "--revocation-key"]
        let options = try Options(arguments, allowed: revocationOptions.union(["--archive", "--envelope", "--keys"]))
        let keys = try JSONDecoder().decode([String: Data].self, from: options.data("--keys"))
        let envelope = try JSONDecoder().decode(ExtensionReleaseEnvelope.self, from: options.data("--envelope"))
        let revocations: ExtensionRevocations?
        if !revocationOptions.isDisjoint(with: options.values.keys) {
            revocations = try ExtensionRevocations.verify(rawPayload: options.data("--revocations"),
                                                         signature: options.signature("--revocation-signature"),
                                                         publicKey: options.publicKey("--revocation-key"))
        } else {
            revocations = nil
        }
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let pins = ExtensionProductionTrust.bundled
        let requiresDeveloperID = pins?.appleSigning == .developerID && pins?.keys[envelope.keyId] != nil
        _ = try ExtensionArchive.stage(options.url("--archive"), in: staging, envelope: envelope,
                                       keys: keys, revocations: revocations, requiresDeveloperID: requiresDeveloperID)
        print("Verified archive, manifest, signature, entitlements and code hashes for \(envelope.id) \(envelope.version).")
    case "sign-revocation":
        let options = try Options(arguments, allowed: ["--document", "--key-env", "--output"])
        let signature = try ExtensionRevocations.sign(rawPayload: options.data("--document"), key: options.privateKey())
        try Data(signature.utf8).write(to: options.url("--output"), options: .atomic)
    case "verify-revocation":
        let options = try Options(arguments, allowed: ["--document", "--signature", "--public-key"])
        let document = try ExtensionRevocations.verify(rawPayload: options.data("--document"),
                                                      signature: options.signature("--signature"),
                                                      publicKey: options.publicKey("--public-key"))
        print("Verified revocation sequence \(document.sequence).")
    default:
        throw CLIError(usage)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("rxcode-extension: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
