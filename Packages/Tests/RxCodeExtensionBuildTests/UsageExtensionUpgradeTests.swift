#if os(macOS)
import CryptoKit
import Foundation
import RxCodeCore
import RxCodeExtensionBuild
import RxCodeExtensionDistribution
import Testing

private actor OfflineCatalog: ExtensionCatalog {
    private(set) var requestCount = 0
    func releases() throws -> [CatalogExtensionRelease] { requestCount += 1; throw URLError(.notConnectedToInternet) }
    func revocations() throws -> (Data, HTTPURLResponse) { requestCount += 1; throw URLError(.notConnectedToInternet) }
    func download(_ release: CatalogExtensionRelease, to file: URL) throws { requestCount += 1; throw URLError(.notConnectedToInternet) }
}

@Suite struct UsageExtensionUpgradeTests {
    private let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func legacyDashboardSelectsNineOfflineProvidersAndRetainsTheMobilePayload() throws {
        let bytes = try Data(contentsOf: tests.appending(path: "Fixtures/BriefingUsageV1/usage-dashboard.json"))
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: bytes)
        let ids = Set(dashboard.integrations.map(\.pluginID))
        #expect(ids == ["ai-usage", "ai-limits", "acp-opencode", "acp-antigravity", "vercel", "neon", "turso", "cloudflare", "github-ci"])
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let resources = BundledUsageExtensions(directory: root)
        for pluginID in ids {
            let id = BundledUsageExtensions.releaseID(for: pluginID)
            let data = Data(id.utf8)
            let envelope = try ExtensionReleaseEnvelope(keyId: "test", id: id, version: "1.0", pluginApi: "2.0",
                sha256: ExtensionReleaseVerifier.digest(data), cdhashes: "arm64:" + String(repeating: "a", count: 40)
                + ",x86_64:" + String(repeating: "b", count: 40)).signed(using: key)
            try data.write(to: root.appending(component: id + ".zip"))
            try JSONEncoder().encode(envelope).write(to: root.appending(component: id + ".sig.json"))
        }
        var selected = Set<String>()
        for integration in dashboard.integrations {
            let (zip, envelope) = try #require(try resources.archivedRelease(for: integration.pluginID))
            try envelope.verifySignature(keys: ["test": key.publicKey.rawRepresentation])
            #expect(ExtensionReleaseVerifier.digest(try Data(contentsOf: zip)) == envelope.sha256)
            selected.insert(envelope.id)
        }
        #expect(selected.count == 9)
        let fixture = tests.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "RxCodeAndroid/app/src/test/resources/briefing-v1/snapshot.json")
        let wire = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let mobile = try #require((wire["data"] as? [String: Any])?["usageDashboard"])
        let encoded = try JSONEncoder().encode(dashboard)
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: encoded), options: [.sortedKeys])
        #expect(try JSONSerialization.data(withJSONObject: mobile, options: [.sortedKeys]) == canonical)
    }

    @Test func failedProviderRefreshRetainsGeminiMetricsAndSuccessTime() throws {
        let bytes = try Data(contentsOf: tests.appending(path: "Fixtures/BriefingUsageV1/usage-dashboard.json"))
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: bytes)
        let integration = try #require(dashboard.integrations.first { $0.pluginID == "acp-antigravity" })
        let saved = try #require(dashboard.snapshots.first { $0.id == integration.id })
        let stale = dashboard.failedSnapshot(for: integration, message: "Review permissions")
        #expect(stale.id == integration.id)
        #expect(stale.metrics == saved.metrics)
        #expect(stale.fetchedAt == saved.fetchedAt)
        #expect(stale.error == "Review permissions")
        let missing = UsageDashboard().failedSnapshot(for: integration, message: "Install extension")
        #expect(missing.fetchedAt == .distantPast && missing.metrics.isEmpty)
    }

    @Test @MainActor func concurrentFetchesCoalesceAndCancelledGenerationsCannotReturnData() async throws {
        let scheduler = ExtensionUsageScheduler()
        let integration = UsageIntegration(pluginID: "ai-usage", title: "AI usage")
        let root = URL(fileURLWithPath: "/project")
        let snapshot = UsagePluginSnapshot(id: integration.id, pluginID: integration.pluginID, title: integration.title,
                                           scope: "", period: "", metrics: [])
        var executions = 0
        let (events, began) = AsyncStream<Void>.makeStream()
        let (ready, complete) = AsyncStream<Void>.makeStream()
        func fetch(_ generation: String) async throws -> UsagePluginSnapshot {
            try await scheduler.fetch(provider: "app.rxlab.extensions.ai-usage", workspace: root,
                                      generation: generation, integration: integration) {
                executions += 1
                began.yield()
                for await _ in ready { break }
                return snapshot
            }
        }
        let first = Task { try await fetch("seed") }
        let second = Task { try await fetch("seed") }
        var started = events.makeAsyncIterator()
        _ = await started.next()
        complete.yield()
        #expect(try await first.value == snapshot)
        #expect(try await second.value == snapshot)
        #expect(executions == 1)
        let stale = Task { try await fetch("seed") }
        _ = await started.next()
        scheduler.invalidate(provider: "app.rxlab.extensions.ai-usage", workspace: root)
        await #expect(throws: CancellationError.self) { try await stale.value }
        complete.finish()
        #expect(try await fetch("update") == snapshot)
        began.finish()
    }

    @Test func rejectedSeedAndExplicitUninstallRemainOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let policyKey = Curve25519.Signing.PrivateKey()
        let remote = OfflineCatalog()
        let resources = BundledUsageExtensions(directory: root)
        let policy = try ExtensionRevocationStore(file: root.appending(path: "policy.json"), publicKey: policyKey.publicKey.rawRepresentation)
        let service = ExtensionCatalogService(support: root.appending(path: "support"), keys: ["test": key.publicKey.rawRepresentation],
            revocations: policy, catalog: remote, activate: { _ in Issue.record("Unauthenticated extension activated") },
            deactivate: { _ in }, blocked: { _ in })
        let id = BundledUsageExtensions.releaseID(for: "acp-antigravity")
        let archive = Data("untrusted archive".utf8)
        let hash = String(repeating: "0", count: 40)
        let envelope = try ExtensionReleaseEnvelope(keyId: "test", id: id, version: "1", pluginApi: "2.0",
            sha256: ExtensionReleaseVerifier.digest(archive), cdhashes: "arm64:" + hash + ",x86_64:" + hash)
            .signed(using: Curve25519.Signing.PrivateKey())
        try JSONEncoder().encode(envelope).write(to: root.appending(component: id + ".sig.json"))
        try archive.write(to: root.appending(component: id + ".zip"))
        await #expect(throws: ExtensionVerificationError.badSignature) {
            try await service.seedUsageProvider("acp-antigravity", from: resources)
        }
        try await service.uninstall(id: id)
        #expect(try await service.seedUsageProvider("acp-antigravity", from: resources) == nil)
        #expect(try await service.installed().isEmpty)
        #expect(await remote.requestCount == 0)
    }
}
#endif
