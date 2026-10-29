import Foundation
import Testing
@testable import RxCodeCore

@Suite("Vercel billing summary")
struct VercelUsageTests {
    @Test func creditsUseBalanceRatherThanLifetimeSpend() throws {
        let metric = try UsageResponseParser.vercelGatewayCredits(Data(#"{"balance":"95.50","total_used":"4.50"}"#.utf8))
        #expect(metric.value == 95.5)
        #expect(metric.unit == "USD")
        #expect(metric.detail?.contains("used to date") == true)
        for json in [#"{"balance":true,"total_used":0}"#, #"{"balance":"NaN","total_used":0}"#,
                     #"{"balance":-1,"total_used":0}"#, #"{"total_used":0}"#] {
            #expect(throws: (any Error).self) { try UsageResponseParser.vercelGatewayCredits(Data(json.utf8)) }
        }
        #expect(try UsageResponseParser.vercel(Data(), project: "").first?.value == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_VERCEL_SIMULATION_URL"] != nil))
    func fetchesBillingAndCreditsOverHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_VERCEL_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let integration = UsageIntegration(pluginID: "vercel", title: "Vercel", account: "team_test", resource: "project_a")
        for key in ["gateway-only", "denied", "malformed", ""] {
            let plugin = CloudUsagePlugin(id: "vercel", vercelAPIBase: base, gatewayAPIBase: base,
                                          gatewayCredential: { _ in key })
            let snapshot = try await plugin.fetch(configuration: integration, credential: "billing-only", now: .now)
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
