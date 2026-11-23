import Foundation
import RxCodeCore
import RxCodeSync
import Testing

@Suite("Pre-migration briefing usage")
struct BriefingUsageBaselineTests {
    private let testsDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func workspaceFile() throws -> Data {
        try Data(contentsOf: testsDirectory.appending(path: "Fixtures/BriefingUsageV1/usage-dashboard.json"))
    }

    @Test func v1FileRetainsTheSavedFieldsAndIdentities() throws {
        let file = try workspaceFile()
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: file)
        let saved = try JSONSerialization.jsonObject(with: file) as? NSDictionary
        let encoded = try JSONEncoder().encode(dashboard)
        #expect(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary == saved)

        #expect(dashboard.version == 1)
        #expect(Set(dashboard.integrations.map(\.pluginID)) == [
            "ai-usage", "ai-limits", "acp-opencode", "acp-antigravity", "vercel", "neon", "turso", "cloudflare", "github-ci"
        ])
        let integrationIDs = Set(dashboard.integrations.map(\.id))
        #expect(integrationIDs.count == dashboard.integrations.count)
        #expect(Set(dashboard.cards.map(\.id)).count == dashboard.cards.count)
        #expect(Set(dashboard.cards.map(\.integrationID)) == integrationIDs)
        #expect(Set(dashboard.snapshots.map(\.id)).count == dashboard.snapshots.count)
        for snapshot in dashboard.snapshots {
            let connection = try #require(dashboard.integrations.first { $0.id == snapshot.id })
            #expect(connection.pluginID == snapshot.pluginID)
            #expect(connection.projectID == snapshot.projectID)
        }
    }

    @Test func sharedViewsRetainTheirSelectionsAndPlacement() throws {
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: workspaceFile())
        let activity = try #require(dashboard.snapshots.first { $0.pluginID == "ai-usage" })
        let views = dashboard.cards.filter { $0.integrationID == activity.id }
        #expect(views.map(\.style) == ["summary", "metrics"])
        let legacy = try #require(views.first)
        #expect(legacy.metricIDs == nil)
        #expect(legacy.selectedMetricIDs == ["turns"])
        #expect(legacy.showInWidget)
        let table = try #require(views.last)
        #expect(table.metricID == "time")
        #expect(table.selectedMetricIDs == ["time", "tokens"])
        #expect(table.cardSize == .xlarge)
        #expect(activity.metrics.filter { table.includesMetric($0.id) }.map(\.id) == ["tokens", "time"])

        let all = try #require(dashboard.cards.first { dashboard.snapshot(for: $0)?.pluginID == "vercel" })
        #expect(all.metricIDs == [])
        #expect(all.includesMetric("USD|Compute"))
        let hidden = try #require(dashboard.cards.first { dashboard.snapshot(for: $0)?.pluginID == "turso" })
        #expect(hidden.showInMenuBar)
        #expect(!dashboard.visibleCards().contains(hidden))
        let pending = try #require(dashboard.integrations.first { $0.account == "org-pending" })
        let pendingCard = try #require(dashboard.cards.first { $0.integrationID == pending.id })
        #expect(pendingCard.isVisible)
        #expect(dashboard.snapshot(for: pendingCard) == nil)
        #expect(!dashboard.visibleCards().contains(pendingCard))
        let project = try #require(activity.projectID)
        #expect(dashboard.visibleCards(projectIDs: [project]).contains(table))
        #expect(!dashboard.visibleCards(projectIDs: [Project.globalChatID]).contains(table))
    }

    @Test func failedRefreshKeepsTheWorkerObservationReadableAmongOtherAccountResources() throws {
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: workspaceFile())
        let connections = dashboard.integrations.filter { $0.pluginID == "cloudflare" }
        #expect(connections.map(\.resource) == ["", "fixture-zone", "worker:fixture-worker", "r2:fixture-bucket"])
        let worker = try #require(connections.first { $0.resource == "worker:fixture-worker" })
        let card = try #require(dashboard.cards.first { $0.integrationID == worker.id })
        let snapshot = try #require(dashboard.snapshot(for: card))
        #expect(snapshot.error?.contains("403") == true)
        #expect(snapshot.isStale(at: snapshot.fetchedAt))
        #expect(snapshot.fetchedAt == Date(timeIntervalSinceReferenceDate: 799_992_800))
        let response = Data(#"{"data":{"viewer":{"accounts":[{"activity":[{"sum":{"requests":70,"errors":0}}]}]}}}"#.utf8)
        #expect(snapshot.metrics == (try CloudflareResourceUsage.metrics(response, resource: worker.resource)))
        #expect(dashboard.visibleCards().contains(card))
    }

    @Test func populatedWorkspaceProducesTheRecordedMobilePayload() throws {
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: workspaceFile())
        let root = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appending(path: "RxCodeAndroid/app/src/test/resources/briefing-v1/snapshot.json"))
        let payload = try JSONDecoder().decode(Payload.self, from: fixture)
        guard case .snapshot(let inbound) = payload else {
            Issue.record("Expected a mobile snapshot")
            return
        }
        #expect(inbound.usageDashboard == dashboard)
        let project = try #require(inbound.projects.first)
        #expect(Set(dashboard.snapshots.compactMap(\.projectID)) == [project.id])
        let outbound = Payload.snapshot(.init(projects: [project], sessions: [], usageDashboard: dashboard))
        let encoded = try JSONEncoder().encode(outbound)
        let wire = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        #expect(try JSONSerialization.jsonObject(with: fixture) as? NSDictionary == wire)

        let limits = try #require(dashboard.snapshots.first { $0.pluginID == "ai-limits" })
        #expect(try #require(limits.metrics.first { $0.id == "codex:5h" }).value == nil)
        #expect(try #require(limits.metrics.first { $0.id == "codex:7d" }).value == 0)
        let acp = try #require(dashboard.snapshots.first { $0.pluginID == "acp-antigravity" })
        let windows = try #require(acp.acpQuotaWindows())
        #expect(windows.fiveHour?.id == "0:gemini-5h")
        #expect(windows.weekly?.resetsAt == Date(timeIntervalSinceReferenceDate: 800_086_400))
    }
}
