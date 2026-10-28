import Foundation
import Testing
@testable import RxCodeCore

@Suite("Usage plugins")
struct UsagePluginTests {
    @Test func vercelPreservesCurrenciesAndProjectScope() throws {
        let rows = """
        {"BilledCost":"1.25","BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"a"}}
        {"BilledCost":2,"BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"a"}}
        {"BilledCost":9,"BillingCurrency":"EUR","ServiceName":"Compute","Tags":{"ProjectId":"b"}}
        """
        let metrics = try UsageResponseParser.vercel(Data(rows.utf8), project: "a")
        #expect(metrics.count == 1)
        #expect(metrics.first?.value == 3.25)
        #expect(metrics.first?.unit == "USD")
        #expect(try UsageResponseParser.vercel(Data(rows.utf8), project: "").count == 2)
    }
    @Test func tursoDoesNotDoubleCountInstances() throws {
        let data = Data(#"{"database":{"instances":[{"usage":{"rows_read":10}}],"total":{"rows_read":10,"rows_written":2,"storage_bytes":4096,"bytes_synced":0}}}"#.utf8)
        #expect(try UsageResponseParser.turso(data, database: true).first?.value == 10)
    }
    @Test func neonAggregatesTimeframesAndPreservesCursor() throws {
        let data = Data(#"{"projects":[{"periods":[{"consumption":[{"metrics":[{"metric_name":"compute_unit_seconds","value":84}]},{"metrics":[{"metric_name":"compute_unit_seconds","value":236}]}]}]}],"pagination":{"cursor":"next"}}"#.utf8)
        let result = try UsageResponseParser.neon(data)
        #expect(result.totals["compute_unit_seconds"] == 320)
        #expect(result.cursor == "next")
    }
    @Test func rejectsErrorEnvelopesAndMalformedNumbers() {
        #expect(throws: (any Error).self) { try UsageResponseParser.cloudflare(Data(#"{"success":false,"result":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try UsageResponseParser.vercel(Data(#"{"BilledCost":true,"BillingCurrency":"USD","ServiceName":"Compute"}"#.utf8), project: "") }
        #expect(throws: (any Error).self) { try UsageResponseParser.neon(Data(#"{"error":"denied"}"#.utf8)) }
    }
    @Test func ciWeightsPRsEquallyAndDeduplicates() {
        let samples: [CIWaitSample] = [
            .init(id: "a", repository: "a/b", pr: 1, seconds: 10),
            .init(id: "b", repository: "a/b", pr: 1, seconds: 30),
            .init(id: "a", repository: "a/b", pr: 1, seconds: 10),
            .init(id: "c", repository: "a/b", pr: 2, seconds: 100)
        ]
        let metrics = CIWaitSample.metrics(samples)
        #expect(metrics.first?.value == 60)
        #expect(metrics.first { $0.id == "a/b#1" }?.value == 20)
        #expect(CIWaitSample.metrics([]).first?.value == nil)
    }
    @Test func multipleViewsRoundTripWithoutCredentials() throws {
        let integration = UsageIntegration(pluginID: "neon", title: "Neon", account: "org")
        let dashboard = UsageDashboard(integrations: [integration], cards: [
            .init(integrationID: integration.id), .init(integrationID: integration.id, style: "compact")
        ])
        let data = try JSONEncoder().encode(dashboard)
        #expect(try JSONDecoder().decode(UsageDashboard.self, from: data) == dashboard)
        #expect(dashboard.cards[0].id != dashboard.cards[1].id)
        #expect(!String(decoding: data, as: UTF8.self).contains("credential"))
    }
    @Test func staleDataRemainsExplicit() {
        let snapshot = UsagePluginSnapshot(id: UUID(), pluginID: "neon", title: "Neon", scope: "org", period: "month", fetchedAt: .distantPast, metrics: [])
        #expect(snapshot.isStale())
        #expect(UsageMetric("x", "x", value: nil, unit: "USD").formattedValue == "Unavailable")
    }
}
