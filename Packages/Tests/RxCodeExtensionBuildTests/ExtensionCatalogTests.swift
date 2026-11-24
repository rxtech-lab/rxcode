#if os(macOS)
import CryptoKit
import Foundation
import Testing
import RxCodeExtensionBuild
import RxCodeExtensionDistribution

private actor FixtureCatalog: ExtensionCatalog {
    var requests = 0
    var archive: URL?
    var policy: (Data, HTTPURLResponse)?
    func releases() async throws -> [CatalogExtensionRelease] { requests += 1; return [] }
    func download(_ release: CatalogExtensionRelease, to file: URL) async throws {
        requests += 1
        try FileManager.default.copyItem(at: try #require(archive), to: file)
    }
    func revocations() async throws -> (Data, HTTPURLResponse) {
        requests += 1
        return try #require(policy)
    }
    func serve(_ zip: URL) { archive = zip }
    func serve(_ raw: Data, signature: String) throws {
        policy = (raw, try #require(HTTPURLResponse(url: URL(fileURLWithPath: "/policy"), statusCode: 200, httpVersion: nil,
                                                    headerFields: ["X-RxCode-Signature": signature])))
    }
}

private actor Registrations {
    var events: [String] = []
    var rejectUpdate = false
    func simulateFailure(_ value: Bool) { rejectUpdate = value }
    func activate(_ release: InstalledRelease) throws {
        let version = release.envelope.version
        events.append("activate " + version)
        if rejectUpdate && version == "2.0" { throw CocoaError(.executableNotLoadable) }
    }
    func deactivate(_ release: InstalledRelease) throws {
        let version = release.envelope.version
        events.append("deactivate " + version)
        if rejectUpdate && version == "2.0" { throw CocoaError(.fileNoSuchFile) }
    }
    func block(_ id: String) { events.append("block " + id) }
}

@Suite struct ExtensionCatalogTests {
    @Test func offlineSeedUpdateRollbackRevocationAndUserChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let source = root.appending(path: "source")
        try fm.createDirectory(at: source.appending(path: "Sources"), withIntermediateDirectories: true)
        try Data("Fixture".utf8).write(to: source.appending(path: "README.md"))
        let code = """
        import ExtensionFoundation
        import RxCodeExtensionSDK
        @main struct CatalogFixture: AppExtension {
            var configuration: some AppExtensionConfiguration {
                ExtensionService.configuration(scenes: [], test: { $0 })
            }
        }
        """
        try Data(code.utf8).write(to: source.appending(path: "Sources/Entry.swift"))
        let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey(), offline = Curve25519.Signing.PrivateKey()
        let id = "app.rxlab.extensions.test-provider"
        func release(_ version: String, signer: Curve25519.Signing.PrivateKey, keyID: String) throws -> (URL, ExtensionReleaseEnvelope, CatalogExtensionRelease) {
            let manifest = """
            {"id":"\(id)","name":"Lifecycle","version":"\(version)","pluginAPI":"2.0","readme":"README.md",
            "permissions":[],"contributes":{"usage.provider":[{"pluginID":"test-provider","title":"Test"}]}}
            """
            try Data(manifest.utf8).write(to: source.appending(path: "extension.json"))
            let bundle = root.appending(path: version + "/Lifecycle.app")
            try ExtensionPackageBuilder.build(directory: source, output: bundle, signer: "-")
            let archive = root.appending(path: version + ".zip")
            let metadata = try ExtensionPackageBuilder.package(bundle: bundle, archive: archive)
            let signed = try ExtensionReleaseEnvelope(keyId: keyID, id: id, version: version, pluginApi: metadata.pluginApi,
                                                     sha256: metadata.sha256, cdhashes: metadata.cdhashes).signed(using: signer)
            var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as? [String: Any])
            fields["signatureFormat"] = signed.format
            fields["name"] = "Lifecycle"
            fields["size"] = metadata.size
            let advertised = try JSONDecoder().decode(CatalogExtensionRelease.self, from: JSONSerialization.data(withJSONObject: fields))
            return (archive, signed, advertised)
        }
        let seed = try release("1.0", signer: a, keyID: "A")
        let update = try release("2.0", signer: b, keyID: "B")
        let catalog = FixtureCatalog(), monitor = Registrations()
        let support = root.appending(path: "support")
        let policy = try ExtensionRevocationStore(file: support.appending(path: "extension-revocations.json"),
                                                  publicKey: offline.publicKey.rawRepresentation)
        let keys = ["A": a.publicKey.rawRepresentation, "B": b.publicKey.rawRepresentation]
        func service() -> ExtensionCatalogService {
            ExtensionCatalogService(support: support, keys: keys, revocations: policy, catalog: catalog,
                                    activate: { try await monitor.activate($0) }, deactivate: { try await monitor.deactivate($0) },
                                    blocked: { await monitor.block($0) })
        }
        let host = service()
        let bundled = BundledUsageExtensions(directory: root)
        try fm.copyItem(at: seed.0, to: root.appending(component: id + ".zip"))
        try JSONEncoder().encode(seed.1).write(to: root.appending(component: id + ".sig.json"))
        let seeded = try await host.seedUsageProvider("test-provider", from: bundled)
        #expect(seeded?.source == .bundled)
        #expect(await catalog.requests == 0)
        await monitor.simulateFailure(true)
        await catalog.serve(update.0)
        await #expect(throws: CocoaError.self) { try await host.install(update.2, explicit: false) }
        #expect(try await host.verifiedForActivation(id: id).envelope == seed.1)
        #expect(await monitor.events.last == "activate 1.0")
        await monitor.simulateFailure(false)

        _ = try await host.install(update.2, explicit: false)
        #expect(try await host.install(seed.0, envelope: seed.1, source: .bundled)?.envelope == update.1)
        await #expect(throws: ExtensionCatalogService.InstallError.downgrade) {
            try await host.install(seed.0, envelope: seed.1, source: .flowcy)
        }
        _ = try await host.install(seed.0, envelope: seed.1, source: .flowcy, explicit: true, allowDowngrade: true)

        let raw = Data("""
        {"format":"rxcode-revocations-v1","sequence":1,"issuedAt":"2026-01-01T00:00:00Z",
        "revokedKeyIds":["A"],"revokedReleases":[]}
        """.utf8)
        try await catalog.serve(raw, signature: ExtensionRevocations.sign(rawPayload: raw, key: offline))
        try await host.refreshRevocations()
        #expect(await monitor.events.last == "block " + id)
        await #expect(throws: ExtensionVerificationError.revoked) { try await host.verifiedForActivation(id: id) }
        #expect(try await host.install(update.2, explicit: false)?.source == .flowcy)
        let installed = try await host.verifiedForActivation(id: id)
        #expect(installed.envelope == update.1)
        let stored = installed.container.deletingLastPathComponent().appending(component: id + ".sig.json")
        let original = try Data(contentsOf: stored)
        var tampered = update.1
        tampered.cdhashes = tampered.cdhashes.replacingOccurrences(of: try #require(tampered.architectureHashes()["arm64"]),
                                                                 with: String(repeating: "0", count: 40))
        try JSONEncoder().encode(tampered).write(to: stored)
        await #expect(throws: ExtensionVerificationError.badSignature) { try await host.verifiedForActivation(id: id) }
        try original.write(to: stored)
        try await host.setEnabled(false, id: id)
        #expect(try await service().install(update.0, envelope: update.1, source: .bundled) == nil)
        try await host.setEnabled(true, id: id)
        try await host.uninstall(id: id)
        let restarted = service()
        #expect(try await restarted.isUninstalled(id: id))
        #expect(try await restarted.seedUsageProvider("test-provider", from: bundled) == nil)
        #expect(try await restarted.install(update.0, envelope: update.1, source: .bundled) == nil)
        #expect(try await restarted.installed().isEmpty)
        #expect(try await restarted.install(update.0, envelope: update.1, source: .bundled, explicit: true)?.envelope == update.1)

        // Debug seeds and production downloads have independent offline authorities and sequence histories.
        let debugSigner = Curve25519.Signing.PrivateKey()
        let debugPolicy = try ExtensionRevocationStore(file: support.appending(path: "debug-policy.json"),
                                                      publicKey: debugSigner.publicKey.rawRepresentation)
        let splitHost = ExtensionCatalogService(support: support, keys: keys, revocations: policy, catalog: catalog,
            catalogKeys: ["B": b.publicKey.rawRepresentation],
            bundledPolicy: .init(keyIDs: ["A"], store: debugPolicy, useForCatalog: false),
            activate: { _ in }, deactivate: { _ in }, blocked: { await monitor.block($0) })
        let seedDocument = Data("""
        {"format":"rxcode-revocations-v1","sequence":99,"issuedAt":"2026-01-01T00:00:00Z",
        "revokedKeyIds":["A","B"],"revokedReleases":[]}
        """.utf8)
        let debugSignature = try ExtensionRevocations.sign(rawPayload: seedDocument, key: debugSigner)
        try await splitHost.seedBaseline(data: seedDocument, signature: debugSignature)
        #expect(try await splitHost.verifiedForActivation(id: id).envelope == update.1)
        await #expect(throws: ExtensionVerificationError.revoked) {
            try await splitHost.install(seed.0, envelope: seed.1, source: .bundled, allowDowngrade: true)
        }
        await #expect(throws: ExtensionVerificationError.unknownKey) {
            try await splitHost.install(seed.2, explicit: true)
        }
        try await catalog.serve(seedDocument, signature: debugSignature)
        await #expect(throws: ExtensionVerificationError.badSignature) { try await splitHost.refreshRevocations() }
        let productionDocument = Data("""
        {"format":"rxcode-revocations-v1","sequence":2,"issuedAt":"2026-01-01T00:00:00Z",
        "revokedKeyIds":["B"],"revokedReleases":[]}
        """.utf8)
        try await catalog.serve(productionDocument, signature: ExtensionRevocations.sign(rawPayload: productionDocument, key: offline))
        try await splitHost.refreshRevocations()
        await #expect(throws: ExtensionVerificationError.revoked) { try await splitHost.verifiedForActivation(id: id) }
        #expect(await debugPolicy.current?.sequence == 99)
        #expect(await policy.current?.sequence == 2)
    }
}
#endif
