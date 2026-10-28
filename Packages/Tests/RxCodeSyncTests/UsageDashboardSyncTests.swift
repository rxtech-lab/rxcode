import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Usage dashboard sync")
struct UsageDashboardSyncTests {
    @Test func olderDesktopRemainsCompatible() throws {
        let old = Data(#"{"projects":[],"sessions":[]}"#.utf8)
        #expect(try JSONDecoder().decode(SnapshotPayload.self, from: old).usageDashboard == nil)
    }
    @Test func cardsAndAIStatsRoundTrip() throws {
        let id = UUID()
        let dashboard = UsageDashboard(cards: [.init(integrationID: id)], snapshots: [
            .init(id: id, pluginID: "ai-usage", title: "AI", scope: "All projects", period: "Last 7 days", metrics: [.init("tokens", "Tokens", value: 120, unit: "tokens")])
        ])
        let payload = SnapshotPayload(projects: [], sessions: [], usageDashboard: dashboard)
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(SnapshotPayload.self, from: data).usageDashboard == dashboard)
    }
    @Test func widgetProjectionIsBoundedAndBackwardCompatible() throws {
        let row = UsageWidgetCardPayload(id: "a", title: String(repeating: "界", count: 100), value: "120 tokens", detail: "Last 7 days", fetchedAt: 0)
        let rows = UsageWidgetCardPayload.bounded(Array(repeating: row, count: 20))
        #expect(rows.count <= 3)
        #expect(try JSONEncoder().encode(rows).count <= 1500)
        let old = try JSONDecoder().decode(WidgetSnapshotPayload.self, from: Data(#"{"updatedAt":0}"#.utf8))
        #expect(old.usageCards == nil)
        let payload = WidgetSnapshotPayload(usageCards: rows, updatedAt: 0)
        let decoded = try JSONDecoder().decode(WidgetSnapshotPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.usageCards?.count == rows.count)
    }

}
