import Foundation
import Testing
@testable import RxCodeExtensionDistribution

private struct Vectors: Decodable {
    struct Release: Decodable {
        let name: String
        let envelope: ExtensionReleaseEnvelope
        let error: String?
    }
    struct Revocation: Decodable {
        let name: String
        let rawPayload: String
        let signature: String
        let error: String?
        var bytes: Data { Data(rawPayload.utf8) }
    }

    let keys: [String: Data]
    let revocationKey: Data
    let archiveBase64: Data
    let canonicalPayload: String
    let releaseCases: [Release]
    let revocationCases: [Revocation]

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Extensions/TestVectors/verification.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func release(_ name: String) throws -> ExtensionReleaseEnvelope {
        try #require(releaseCases.first { $0.name == name }).envelope
    }
    func revocation(_ name: String) throws -> Revocation {
        try #require(revocationCases.first { $0.name == name })
    }
    func verified(_ name: String) throws -> ExtensionRevocations {
        let item = try revocation(name)
        return try ExtensionRevocations.verify(rawPayload: item.bytes, signature: item.signature, publicKey: revocationKey)
    }
}

private typealias VerificationError = ExtensionVerificationError

@Suite struct ExtensionDistributionTests {
    @Test func crossLanguageVectors() throws {
        let vectors = try Vectors.load()
        let release = try vectors.release("good")
        #expect(try String(decoding: release.canonicalPayload(), as: UTF8.self) == vectors.canonicalPayload)
        #expect(ExtensionReleaseVerifier.digest(vectors.archiveBase64) == release.sha256)
        for item in vectors.releaseCases {
            do {
                try item.envelope.verifySignature(keys: vectors.keys)
                #expect(item.error == nil, "\(item.name)")
            } catch let error as VerificationError {
                #expect(String(describing: error) == item.error, "\(item.name)")
            }
        }
        for item in vectors.revocationCases {
            do {
                _ = try vectors.verified(item.name)
                #expect(item.error == nil, "\(item.name)")
            } catch let error as VerificationError {
                #expect(String(describing: error) == item.error, "\(item.name)")
            }
        }
    }

    @Test func activationAuthenticatesStoredEnvelopeAndCurrentArchitecture() throws {
        let vectors = try Vectors.load()
        let good = try vectors.release("good")
        let hashes = try good.architectureHashes()
        for (architecture, hash) in hashes {
            try good.verifyActivation(architecture: architecture, codeHash: hash, keys: vectors.keys, revocations: nil)
            let wrong = String(repeating: "d", count: 40)
            #expect(throws: VerificationError.codeHashMismatch) {
                try good.verifyActivation(architecture: architecture, codeHash: wrong, keys: vectors.keys, revocations: nil)
            }
            var modified = good
            modified.cdhashes = modified.cdhashes.replacingOccurrences(of: hash, with: wrong)
            #expect(throws: VerificationError.badSignature) {
                try modified.verifyActivation(architecture: architecture, codeHash: wrong, keys: vectors.keys, revocations: nil)
            }
        }
        #expect(throws: VerificationError.codeHashMismatch) {
            try ExtensionReleaseVerifier.verifyAllCodeHashes(["arm64": hashes["arm64"]!], envelope: good)
        }
    }

    @Test func revokedKeyAndReleaseApplyToInstallsAndActivation() throws {
        let vectors = try Vectors.load()
        let active = try vectors.release("good")
        let backup = try vectors.release("backup")
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try vectors.archiveBase64.write(to: url)
        for policy in ["activeKey", "release"] {
            let revocations = try vectors.verified(policy)
            #expect(throws: VerificationError.revoked) {
                try ExtensionReleaseVerifier.verify(archive: url, envelope: active, keys: vectors.keys, revocations: revocations)
            }
            #expect(throws: VerificationError.revoked) {
                try active.verifyActivation(architecture: "arm64", codeHash: active.architectureHashes()["arm64"]!,
                                            keys: vectors.keys, revocations: revocations)
            }
        }
        try ExtensionReleaseVerifier.verify(archive: url, envelope: backup, keys: vectors.keys,
                                           revocations: vectors.verified("activeKey"))
        try Data("changed".utf8).write(to: url)
        #expect(throws: VerificationError.digestMismatch) {
            try ExtensionReleaseVerifier.verify(archive: url, envelope: backup, keys: vectors.keys, revocations: nil)
        }
    }

    #if DEBUG
    @Test func migratingPreviewPolicyPreservesTheOtherAuthorityAndNewerSequence() async throws {
        let vectors = try Vectors.load()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = directory.appending(path: "extension-revocations.json")
        let legacy = try ExtensionRevocationStore(file: previous, publicKey: vectors.revocationKey)
        let baseline = try vectors.revocation("baseline")
        try await legacy.loadBaseline(rawPayload: baseline.bytes, signature: baseline.signature)

        let separate = try ExtensionRevocationStore(file: directory.appending(path: "other/policy.json"),
                                                    publicKey: try #require(vectors.keys["test-active"]))
        try await separate.migrateSignedBaseline(from: previous)
        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(await separate.current == nil)

        let destination = directory.appending(path: "DebugExtensions/extension-revocations.json")
        let preview = try ExtensionRevocationStore(file: destination, publicKey: vectors.revocationKey)
        let latest = try vectors.revocation("activeKey")
        try await preview.loadBaseline(rawPayload: latest.bytes, signature: latest.signature)
        try await preview.migrateSignedBaseline(from: previous)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        let reopened = try ExtensionRevocationStore(file: destination, publicKey: vectors.revocationKey)
        #expect(await reopened.current?.sequence == 2)
    }
    #endif

    @Test func baselineAndRefreshPreserveHighestVerifiedSequenceAcrossRelaunches() async throws {
        let vectors = try Vectors.load()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "extension-revocations.json")
        let store = try ExtensionRevocationStore(file: file, publicKey: vectors.revocationKey)
        let baseline = try vectors.revocation("baseline")
        let latest = try vectors.revocation("activeKey")
        try await store.loadBaseline(rawPayload: baseline.bytes, signature: baseline.signature)
        #expect(await store.current?.sequence == 1)
        let source = try #require(URL(string: "https://example.test/revocations"))
        let ok = try #require(HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil,
                                              headerFields: ["X-RxCode-Signature": latest.signature]))
        #expect(try await store.refresh(bytes: latest.bytes, response: ok)?.sequence == 2)
        for old in [latest, baseline] {
            await #expect(throws: VerificationError.staleSequence) {
                try await store.accept(rawPayload: old.bytes, signature: old.signature)
            }
        }
        let missing = try #require(HTTPURLResponse(url: source, statusCode: 404, httpVersion: nil, headerFields: nil))
        #expect(try await store.refresh(bytes: Data(), response: missing) == nil)
        let failed = try #require(HTTPURLResponse(url: source, statusCode: 503, httpVersion: nil, headerFields: nil))
        await #expect(throws: URLError.self) { try await store.refresh(bytes: Data(), response: failed) }
        await #expect(throws: VerificationError.badSignature) {
            try await store.refresh(bytes: baseline.bytes, response: ok)
        }
        let reopened = try ExtensionRevocationStore(file: file, publicKey: vectors.revocationKey)
        try await reopened.loadBaseline(rawPayload: baseline.bytes, signature: baseline.signature)
        #expect(await reopened.current == store.current)
    }
}
