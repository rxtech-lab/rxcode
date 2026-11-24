import Foundation
import Testing
import ExtensionTestSupport
import RxCodeExtensionSDK
@testable import CloudflareUsage

@Suite("Cloudflare account discovery")
struct CloudflareAccountsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"] != nil))
    func fetchesCurrentBillingPeriodOverHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let integration = try FixtureBroker.integration(pluginID: "cloudflare", title: "Cloudflare", account: String(repeating: "a", count: 32))
        let snapshot = try await CloudflareUsage.fetch(integration, host: FixtureBroker.host(baseURL: base, slots: ["primary": "fixture"]), now: .now)
        #expect(snapshot.period == "Current billing period")
        // Per-period BilledCost is summed; cumulative cost fields are ignored.
        #expect(snapshot.metrics.first?.id == "billable|USD")
        #expect(abs((snapshot.metrics.first?.value ?? 0) - 2.03) < 0.0001)
        #expect(snapshot.metrics.first?.unit == "USD")
        #expect(snapshot.metrics.first { $0.id == "Workers Standard|requests" }?.value == 400000)
        #expect(snapshot.metrics.first { $0.id == "R2 Storage|GB-months" }?.value == 2)
        do {
            _ = try await CloudflareUsage.fetch(integration, host: FixtureBroker.host(baseURL: base, slots: ["primary": "denied"]), now: .now)
            Issue.record("Expected billing access denial")
        } catch let error as ExtensionUsageFailure {
            let message = error.message
            #expect(message.contains("billing"))
            #expect(message.contains("API token"))
            #expect(message.contains("R2"))
        }
        await #expect(throws: (any Error).self) {
            try await CloudflareUsage.fetch(integration, host: FixtureBroker.host(baseURL: base, slots: ["primary": "malformed"]), now: .now)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"] != nil))
    func billingTokenReplacesOAuthCredentialForAccountUsage() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let integration = try FixtureBroker.integration(pluginID: "cloudflare", title: "Cloudflare", account: String(repeating: "a", count: 32))
        // The OAuth credential lacks billing access; only the billing token reaches billable usage.
        let host = FixtureBroker.host(baseURL: base, slots: ["billing": "fixture", "oauth": "denied"])
        let snapshot = try await CloudflareUsage.fetch(integration, host: host, now: .now)
        #expect(snapshot.metrics.first { $0.id == "Workers Standard|requests" }?.value == 400000)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("fixture"))
        let deniedToken = FixtureBroker.host(baseURL: base, slots: ["billing": "denied", "oauth": "fixture"])
        do {
            _ = try await CloudflareUsage.fetch(integration, host: deniedToken, now: .now)
            Issue.record("Expected billing token denial")
        } catch let error as ExtensionUsageFailure {
            let message = error.message
            #expect(message.contains("Billing > Read"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"] != nil))
    func discoversAccountsOverHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_CLOUDFLARE_SIMULATION_URL"])
        let base = try #require(URL(string: address))
        let accounts = try await CloudflareAccounts.list(host: FixtureBroker.host(baseURL: base, slots: ["oauth": "fixture"]))
        #expect(accounts.count == 51)
        #expect(accounts.contains { $0.id == String(repeating: "a", count: 32) })
        #expect(!accounts.contains { $0.id == String(repeating: "b", count: 32) })
        #expect(accounts.map(\.name) == accounts.map(\.name).sorted())
        for token in ["denied", "malformed"] {
            await #expect(throws: (any Error).self) {
                try await CloudflareAccounts.list(host: FixtureBroker.host(baseURL: base, slots: ["oauth": token]))
            }
        }
    }
}
