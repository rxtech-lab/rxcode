import ExtensionTestSupport
import Foundation
import Testing
@testable import VercelUsage

struct VercelSimulationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_VERCEL_SIMULATION_URL"] != nil))
    func fetchesBillingAndCreditsOverHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_VERCEL_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let integration = try FixtureBroker.integration(pluginID: "vercel", title: "Vercel", account: "team_test", resource: "project_a")
        for key in ["gateway-only", "denied", "malformed", ""] {
            let host = FixtureBroker.host(baseURL: base, slots: ["primary": "billing-only", "gateway": key])
            let snapshot = try await VercelUsage.fetch(integration, host: host, now: .now)
            #expect(snapshot.metrics.first?.id == "billable|USD")
            #expect(snapshot.metrics.first?.value == 42.64)
            #expect(snapshot.metrics[1].id == "ai-gateway-balance")
            #expect(snapshot.metrics[1].value == (key == "gateway-only" ? 95.5 : nil))
            #expect(snapshot.metrics[1].detail != nil)
            #expect(snapshot.metrics.first { $0.id == "USD|Compute" }?.value == 42.64)
            #expect(snapshot.period == "Last 30 days")
            #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("gateway-only"))
        }
    }
}
