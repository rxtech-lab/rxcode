import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cloudflare account discovery")
struct CloudflareAccountsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"] != nil))
    func fetchesCurrentBillingPeriodOverHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let plugin = CloudUsagePlugin(id: "cloudflare", cloudflareAPIBase: base)
        let integration = UsageIntegration(pluginID: "cloudflare", title: "Cloudflare", account: String(repeating: "a", count: 32))
        let snapshot = try await plugin.fetch(configuration: integration, credential: "fixture", now: .now)
        #expect(snapshot.period == "Current billing period")
        // Per-period BilledCost is summed; cumulative cost fields are ignored.
        #expect(snapshot.metrics.first?.id == "billable|USD")
        #expect(abs((snapshot.metrics.first?.value ?? 0) - 2.03) < 0.0001)
        #expect(snapshot.metrics.first?.unit == "USD")
        #expect(snapshot.metrics.first { $0.id == "Workers Standard|requests" }?.value == 400000)
        #expect(snapshot.metrics.first { $0.id == "R2 Storage|GB-months" }?.value == 2)
        do {
            _ = try await plugin.fetch(configuration: integration, credential: "denied", now: .now)
            Issue.record("Expected billing access denial")
        } catch UsagePluginError.provider(let status, let message) {
            #expect(status == 403)
            #expect(message.contains("billing"))
            #expect(message.contains("API token"))
            #expect(message.contains("R2"))
        }
        await #expect(throws: (any Error).self) {
            try await plugin.fetch(configuration: integration, credential: "malformed", now: .now)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"] != nil))
    func billingTokenReplacesOAuthCredentialForAccountUsage() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let integration = UsageIntegration(pluginID: "cloudflare", title: "Cloudflare", account: String(repeating: "a", count: 32))
        // The OAuth credential lacks billing access; only the billing token reaches billable usage.
        let plugin = CloudUsagePlugin(id: "cloudflare", cloudflareAPIBase: base, billingCredential: { _ in "fixture" })
        let snapshot = try await plugin.fetch(configuration: integration, credential: "denied", now: .now)
        #expect(snapshot.metrics.first { $0.id == "Workers Standard|requests" }?.value == 400000)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("fixture"))
        let deniedToken = CloudUsagePlugin(id: "cloudflare", cloudflareAPIBase: base, billingCredential: { _ in "denied" })
        do {
            _ = try await deniedToken.fetch(configuration: integration, credential: "fixture", now: .now)
            Issue.record("Expected billing token denial")
        } catch UsagePluginError.provider(let status, let message) {
            #expect(status == 403)
            #expect(message.contains("Billing > Read"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"] != nil))
    func discoversAccountsOverHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let accounts = try await CloudflareAccounts.list(token: "fixture", baseURL: base)
        #expect(accounts.count == 51)
        #expect(accounts.contains { $0.id == String(repeating: "a", count: 32) })
        #expect(!accounts.contains { $0.id == String(repeating: "b", count: 32) })
        #expect(accounts.map(\.name) == accounts.map(\.name).sorted())
        for token in ["denied", "malformed"] {
            await #expect(throws: (any Error).self) {
                try await CloudflareAccounts.list(token: token, baseURL: base)
            }
        }
    }
}
