#if os(macOS)
import CryptoKit
import Foundation
import RxCodeCore
import RxCodeExtensionBuild
import RxCodeExtensionDistribution
import Testing

/// Only the catalog transport and operating-system registration are replaced in this drill.
private actor RotationCatalog: ExtensionCatalog {
    private var files: [String: (CatalogExtensionRelease, URL)] = [:]
    private var policy: (Data, HTTPURLResponse)?
    private(set) var requests = 0

    func publish(_ release: CatalogExtensionRelease, archive: URL) {
        files[release.id] = (release, archive)
    }

    func publishPolicy(_ data: Data, key: Curve25519.Signing.PrivateKey) throws {
        let signature = try ExtensionRevocations.sign(rawPayload: data, key: key)
        policy = (data, try #require(HTTPURLResponse(url: URL(fileURLWithPath: "/revocations"), statusCode: 200,
                                                    httpVersion: nil, headerFields: ["X-RxCode-Signature": signature])))
    }

    func releases() -> [CatalogExtensionRelease] {
        requests += 1
        return files.values.map(\.0).sorted { $0.id < $1.id }
    }

    func revocations() throws -> (Data, HTTPURLResponse) {
        requests += 1
        return try #require(policy)
    }

    func download(_ release: CatalogExtensionRelease, to file: URL) throws {
        requests += 1
        let (entry, archive) = try #require(files[release.id])
        #expect(entry == release)
        try FileManager.default.copyItem(at: archive, to: file)
    }
}

@MainActor private final class RotationSessions {
    var generations: [String: String] = [:]
    let scheduler = ExtensionUsageScheduler()
    private var slowResponse: CheckedContinuation<Void, Never>?
    let started = AsyncStream<Void>.makeStream()

    func activate(_ release: InstalledRelease) { generations[release.envelope.id] = release.envelope.sha256 }
    func close(_ id: String) {
        generations[id] = nil
        scheduler.invalidate(provider: id + ".service")
    }

    func delayedSnapshot(for integration: UsageIntegration, workspace: URL) async throws -> UsagePluginSnapshot {
        let id = BundledUsageExtensions.releaseID(for: integration.pluginID)
        let generation = try #require(generations[id])
        return try await scheduler.fetch(provider: id + ".service", workspace: workspace, generation: generation,
                                         integration: integration) {
            await withCheckedContinuation { continuation in
                self.slowResponse = continuation
                self.started.continuation.yield(())
            }
            return UsagePluginSnapshot(id: integration.id, pluginID: integration.pluginID, title: integration.title,
                                       scope: "", period: "", metrics: [])
        }
    }

    func releaseResponse() { slowResponse?.resume(); slowResponse = nil }
}

@Suite struct ExtensionCatalogRotationTests {
    private func build(source: URL, artifacts: URL, keyID: String, key: Curve25519.Signing.PrivateKey) throws -> CatalogExtensionRelease {
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: source.appending(path: "extension.json")))
        let bundle = artifacts.appending(component: manifest.id + ".app")
        try ExtensionPackageBuilder.build(directory: source, output: bundle, signer: "-")
        let archive = artifacts.appending(component: manifest.id + ".zip")
        let metadata = try ExtensionPackageBuilder.package(bundle: bundle, archive: archive)
        let envelope = try ExtensionReleaseEnvelope(keyId: keyID, id: manifest.id, version: manifest.version, pluginApi: manifest.pluginAPI,
                                                   sha256: metadata.sha256, cdhashes: metadata.cdhashes).signed(using: key)
        let encoded = try JSONEncoder().encode(envelope)
        try encoded.write(to: artifacts.appending(component: manifest.id + ".sig.json"))
        var row = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        row["name"] = manifest.name
        row["size"] = metadata.size
        row["signatureFormat"] = envelope.format
        return try JSONDecoder().decode(CatalogExtensionRelease.self, from: JSONSerialization.data(withJSONObject: row))
    }

    @Test(.timeLimit(.minutes(10))) func offlineDashboardSurvivesSigningKeyRotationAndRelaunch() async throws {
        let fm = FileManager.default
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = tests.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Extensions")
        let dashboardURL = tests.appending(path: "Fixtures/BriefingUsageV1/usage-dashboard.json")
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: Data(contentsOf: dashboardURL))
        let providers = Set(dashboard.integrations.map(\.pluginID)).sorted()
        #expect(providers.count == 9)
        let scratch = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: scratch) }
        let bundled = scratch.appending(path: "BundledExtensions")
        let published = scratch.appending(path: "published")
        let sourceCopy = scratch.appending(path: "sources")
        let support = scratch.appending(path: "support")
        for directory in [bundled, published, sourceCopy] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey(), offline = Curve25519.Signing.PrivateKey()
        let keys = ["A": a.publicKey.rawRepresentation, "B": b.publicKey.rawRepresentation]
        let catalog = RotationCatalog()
        let sessions = await RotationSessions()
        func newService() throws -> ExtensionCatalogService {
            let policy = try ExtensionRevocationStore(file: support.appending(path: "extension-revocations.json"),
                                                      publicKey: offline.publicKey.rawRepresentation)
            return ExtensionCatalogService(support: support, keys: keys, revocations: policy, catalog: catalog,
                                           activate: { await sessions.activate($0) }, deactivate: { await sessions.close($0.envelope.id) },
                                           blocked: { await sessions.close($0) })
        }
        let baseline = Data(#"{"format":"rxcode-revocations-v1","sequence":1,"issuedAt":"2026-01-01T00:00:00Z","revokedKeyIds":[],"revokedReleases":[]}"#.utf8)
        let revokedA = Data(#"{"format":"rxcode-revocations-v1","sequence":2,"issuedAt":"2026-01-02T00:00:00Z","revokedKeyIds":["A"],"revokedReleases":[]}"#.utf8)
        let resources = BundledUsageExtensions(directory: bundled)
        let service = try newService()
        try await service.seedBaseline(data: baseline, signature: ExtensionRevocations.sign(rawPayload: baseline, key: offline))
        var seeded: [String: ExtensionReleaseEnvelope] = [:]
        for provider in providers {
            let directory = sources.appending(component: provider)
            let active = try build(source: directory, artifacts: bundled, keyID: "A", key: a)
            let result = try #require(try await service.seedUsageProvider(provider, from: resources))
            #expect(result.manifest.contributes.usageProviders?.map(\.pluginID) == [provider])
            #expect(result.source == .bundled && result.envelope == active.envelope)
            seeded[active.id] = active.envelope

            let updateSource = sourceCopy.appending(component: provider)
            try fm.copyItem(at: directory, to: updateSource)
            let file = updateSource.appending(path: "extension.json")
            var newer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let majorVersion = try #require(Int(active.version.split(separator: ".")[0]))
            newer["version"] = "\(majorVersion + 1).0.0"
            try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys]).write(to: file)
            let updated = try build(source: updateSource, artifacts: published, keyID: "B", key: b)
            await catalog.publish(updated, archive: published.appending(component: updated.id + ".zip"))
        }
        #expect(try await service.installed().count == 9)
        #expect(await catalog.requests == 0)

        let integration = try #require(dashboard.integrations.first { $0.pluginID == "ai-usage" })
        let fetch = Task { try await sessions.delayedSnapshot(for: integration, workspace: scratch) }
        var started = sessions.started.stream.makeAsyncIterator()
        _ = await started.next()
        try await catalog.publishPolicy(revokedA, key: offline)
        try await service.refreshRevocations()
        #expect(await sessions.generations.isEmpty)
        // Return a late, successfully computed snapshot after the policy has invalidated its generation.
        await sessions.releaseResponse()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        for id in seeded.keys {
            await #expect(throws: ExtensionVerificationError.revoked) { try await service.verifiedForActivation(id: id) }
        }

        for release in try await service.available() {
            let installed = try #require(try await service.install(release, explicit: false))
            #expect(installed.source == .flowcy && installed.envelope.keyId == "B")
            #expect(try await service.verifiedForActivation(id: release.id).envelope == release.envelope)
        }
        #expect(await sessions.generations.count == 9)

        // Restoring the authentic A binary, envelope and metadata must still fail after restarting offline.
        let restored = BundledUsageExtensions.releaseID(for: "ai-usage")
        let restoredDirectory = support.appending(path: "Extensions").appending(component: restored)
        try fm.moveItem(at: restoredDirectory.appending(path: "current"), to: restoredDirectory.appending(path: ".retained-B"))
        try fm.copyItem(at: restoredDirectory.appending(path: ".previous"), to: restoredDirectory.appending(path: "current"))
        let restart = try newService()
        try await restart.seedBaseline(data: baseline, signature: ExtensionRevocations.sign(rawPayload: baseline, key: offline))
        await #expect(throws: ExtensionVerificationError.revoked) { try await restart.verifiedForActivation(id: restored) }
        try await catalog.publishPolicy(baseline, key: offline)
        await #expect(throws: ExtensionVerificationError.staleSequence) { try await restart.refreshRevocations() }
        await #expect(throws: ExtensionVerificationError.revoked) { try await restart.verifiedForActivation(id: restored) }
        let id = BundledUsageExtensions.releaseID(for: "vercel")
        try await restart.uninstall(id: id)
        let relaunched = try newService()
        let requests = await catalog.requests
        #expect(try await relaunched.seedUsageProvider("vercel", from: resources) == nil)
        #expect(try await relaunched.isUninstalled(id: id))
        #expect(await catalog.requests == requests)
    }
}
#endif
