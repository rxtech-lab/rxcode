import Foundation
import Testing
@testable import RxCodeCore

@Suite("MCP integration usage")
struct IntegrationUsageReportTests {
    @Test func discoversConnectionsWithoutCardsAndCombinesFilters() throws {
        let vercel = UsageIntegration(pluginID: "vercel", title: "Vercel")
        let neon = UsageIntegration(pluginID: "neon", title: "Neon")
        let dashboard = UsageDashboard(integrations: [vercel, neon])
        let all = try IntegrationUsageQuery(arguments: .object([:]))
        #expect(!all.refresh)
        #expect(all.integrations(in: dashboard) == [vercel, neon])
        let entries = all.report(from: dashboard)["integrations"]?.arrayValue
        #expect(entries?.count == 2)
        #expect(entries?.first?["available"] == .bool(false))
        #expect(entries?.first?["stale"] == .bool(true))
        #expect(entries?.first?["fetched_at"] == .null)
        let filtered = try IntegrationUsageQuery(arguments: .object([
            "plugin_id": .string("vercel"), "integration_id": .string(neon.id.uuidString), "refresh": .bool(true)
        ]))
        #expect(filtered.refresh)
        #expect(filtered.integrations(in: dashboard).isEmpty)
        let selected = try IntegrationUsageQuery(arguments: .object(["plugin_id": .string("vercel")]))
        #expect(selected.integrations(in: dashboard) == [vercel])
    }

    @Test func preservesMetricsAndFailedRefreshObservationTimeWithoutOAuth() throws {
        var integration = UsageIntegration(pluginID: "vercel", title: "Production", account: "team_a", resource: "prj_a")
        integration.oauth = .init(clientID: "excluded-client", callbackURL: "excluded-callback", scopes: "excluded-scope")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsagePluginSnapshot(id: integration.id, pluginID: "vercel", title: integration.title,
            scope: "team_a", period: "Month", fetchedAt: now,
            metrics: [.init("billable|USD", "Billable", value: 12.5, unit: "USD"),
                      .init("unknown", "Unknown", value: nil, unit: "bytes")], error: "Unable to refresh usage.")
        let query = try IntegrationUsageQuery(arguments: .object([:]))
        let report = query.report(from: .init(integrations: [integration], snapshots: [snapshot]), now: now)
        let entry = try #require(report["integrations"]?.arrayValue?.first)
        #expect(entry["available"] == .bool(true))
        #expect(entry["stale"] == .bool(true))
        #expect(entry["fetched_at"] == .string(ISO8601DateFormatter().string(from: now)))
        #expect(entry["metrics"]?.arrayValue?.first?["value"] == .number(12.5))
        #expect(entry["metrics"]?.arrayValue?.first?["unit"] == .string("USD"))
        #expect(entry["metrics"]?.arrayValue?.last?["value"] == .null)
        #expect(entry["error"] == .string("Unable to refresh usage."))
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains("excluded-"))
        var fresh = snapshot
        fresh.error = nil
        let dashboard = UsageDashboard(integrations: [integration], snapshots: [fresh])
        #expect(query.report(from: dashboard, now: now)["integrations"]?.arrayValue?.first?["stale"] == .bool(false))
        #expect(query.report(from: dashboard, now: now.addingTimeInterval(3601))["integrations"]?.arrayValue?.first?["stale"] == .bool(true))
    }

    @Test func rejectsMalformedFiltersAndRefresh() {
        for arguments: JSONValue in [
            .object(["integration_id": .string("invalid")]),
            .object(["plugin_id": .string(" ")]),
            .object(["refresh": .string("true")])
        ] {
            #expect(throws: IDEToolError.self) { try IntegrationUsageQuery(arguments: arguments) }
        }
    }

    @Test func failedFirstFetchIsUnavailable() throws {
        let integration = UsageIntegration(pluginID: "cloudflare", title: "Cloudflare")
        let snapshot = UsagePluginSnapshot(id: integration.id, pluginID: integration.pluginID,
            title: integration.title, scope: "", period: "", fetchedAt: .distantPast,
            metrics: [], error: "Unable to refresh usage.")
        let query = try IntegrationUsageQuery(arguments: .object([:]))
        let entry = query.report(from: .init(integrations: [integration], snapshots: [snapshot]))["integrations"]?.arrayValue?.first
        #expect(entry?["available"] == .bool(false))
        #expect(entry?["stale"] == .bool(true))
        #expect(entry?["fetched_at"] == .null)
        #expect(entry?["error"] == .string("Unable to refresh usage."))
    }

    @Test func registeredForAllIDEProviders() {
        let tool = IDEToolRegistry.allTools.first { $0.name == "ide__get_integration_usage" }
        #expect(tool != nil)
        if case .alwaysIDEOnly = tool?.visibility {} else {
            Issue.record("Integration usage must be available to every IDE provider.")
        }
    }
}
