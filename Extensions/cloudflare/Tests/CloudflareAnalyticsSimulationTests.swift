import ExtensionTestSupport
import Foundation
import Testing
@testable import CloudflareUsage

struct CloudflareAnalyticsSimulationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_USAGE_SIMULATION_URL"] != nil))
    func fetchesThroughRealHTTP() async throws {
        let endpointText = try #require(ProcessInfo.processInfo.environment["RXCODE_USAGE_SIMULATION_URL"])
        let endpoint = try #require(URL(string: endpointText))
        let host = FixtureBroker.host(baseURL: endpoint, slots: ["oauth": "simulation-only"])
        for resource in ["worker:api", "r2:assets"] {
            let integration = try FixtureBroker.integration(pluginID: "cloudflare", title: "Resource", account: "test-account", resource: resource, projectID: UUID())
            let snapshot = try await CloudflareUsage.fetch(integration, host: host, now: Date(timeIntervalSince1970: 1793167200))
            #expect(snapshot.id == integration.id)
            #expect(snapshot.projectID == integration.projectID)
            #expect(snapshot.metrics.first?.value == 42)
            #expect(snapshot.period == "Last 24 hours · analytics")
            #expect(snapshot.error == nil)
        }
        for name in ["denied", "partial"] {
            let integration = try FixtureBroker.integration(pluginID: "cloudflare", title: "Failure", account: "test-account", resource: "worker:" + name)
            await #expect(throws: (any Error).self) {
                try await CloudflareUsage.fetch(integration, host: host, now: .now)
            }
        }
    }
}
