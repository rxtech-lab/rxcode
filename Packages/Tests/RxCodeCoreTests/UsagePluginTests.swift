import Foundation
import Testing
@testable import RxCodeCore

@Suite("Usage plugins")
struct UsagePluginTests {
    @Test func multipleMetricSelectionPreservesLegacyCards() throws {
        let legacy = UsageCardConfiguration(integrationID: UUID(), metricID: "tokens")
        var card = try JSONDecoder().decode(UsageCardConfiguration.self, from: JSONEncoder().encode(legacy))
        #expect(card.selectedMetricIDs == ["tokens"])
        #expect(card.includesMetric("tokens"))
        #expect(!card.includesMetric("time"))
        card.selectMetrics(["tokens", "time", "tokens"])
        let encoded = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(UsageCardConfiguration.self, from: encoded)
        #expect(decoded.selectedMetricIDs == ["tokens", "time"])
        #expect(decoded.includesMetric("time"))
        #expect(!decoded.includesMetric("turns"))
        #expect(decoded.metricID == "tokens")
        card.selectMetrics([])
        #expect(card.metricID == nil)
        #expect(card.includesMetric("new-metric"))
        #expect(try JSONDecoder().decode(UsageCardConfiguration.self, from: JSONEncoder().encode(card)).selectedMetricIDs.isEmpty)
    }
    @Test func vercelPreservesCurrenciesAndProjectScope() throws {
        let rows = """
        {"BilledCost":"1.25","BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"a"}}
        {"BilledCost":2,"BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"a"}}
        {"BilledCost":9,"BillingCurrency":"EUR","ServiceName":"Compute","Tags":{"ProjectId":"b"}}
        """
        let metrics = try UsageResponseParser.vercel(Data(rows.utf8), project: "a")
        #expect(metrics.count == 2)
        #expect(metrics.first?.id == "billable|USD")
        #expect(metrics.first?.value == 3.25)
        #expect(metrics.first?.unit == "USD")
        let all = try UsageResponseParser.vercel(Data(rows.utf8), project: "")
        #expect(all.count == 4)
        #expect(all.first { $0.id == "billable|EUR" }?.value == 9)
        #expect(all.first { $0.id == "USD|Compute" }?.value == 3.25)
    }
    @Test func vercelScopeUsesTeamIDSlugOrDefault() {
        #expect(VercelAccounts.scope("").isEmpty)
        #expect(VercelAccounts.scope("team_abc") == ["teamId": "team_abc"])
        #expect(VercelAccounts.scope(" my-team ") == ["slug": "my-team"])
    }
    @Test func vercelTeamsAndProviderErrorsParse() throws {
        let page = try UsageResponseParser.vercelTeams(Data(#"{"teams":[{"id":"team_a","slug":"a","name":"Acme"},{"id":"team_b","slug":"b","name":""}],"pagination":{"count":2,"next":1700000000000,"prev":null}}"#.utf8))
        #expect(page.teams.map(\.name) == ["Acme", "b"])
        #expect(page.next == 1700000000000)
        #expect(try UsageResponseParser.vercelDefaultTeam(Data(#"{"user":{"id":"u","defaultTeamId":"team_b"}}"#.utf8)) == "team_b")
        #expect(UsageResponseParser.errorMessage(Data(#"{"error":{"code":"forbidden","message":"Not authorized"}}"#.utf8)) == "Not authorized")
        #expect(UsageResponseParser.errorMessage(Data(#"{"errors":[{"message":"bad token"}]}"#.utf8)) == "bad token")
        #expect(UsageResponseParser.errorMessage(Data("not json".utf8)) == nil)
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

    @Test func visibleCardsMatchRenderedProjectScope() {
        let project = UUID()
        let otherProject = UUID()
        let globalID = UUID()
        let projectID = UUID()
        let global = UsageCardConfiguration(integrationID: globalID)
        let scoped = UsageCardConfiguration(integrationID: projectID)
        let hidden = UsageCardConfiguration(integrationID: globalID, isVisible: false)
        let pending = UsageCardConfiguration(integrationID: UUID())
        let dashboard = UsageDashboard(cards: [global, scoped, hidden, pending], snapshots: [
            .init(id: globalID, pluginID: "ai-usage", title: "AI", scope: "All projects", period: "Week", metrics: []),
            .init(id: projectID, pluginID: "neon", title: "Neon", projectID: project, scope: "Project", period: "Month", metrics: [])
        ])
        #expect(dashboard.visibleCards() == [global, scoped])
        #expect(dashboard.visibleCards(projectIDs: [project]) == [global, scoped])
        #expect(dashboard.visibleCards(projectIDs: [otherProject]) == [global])
        #expect(UsageDashboard(cards: [hidden, pending]).visibleCards().isEmpty)
    }
}
