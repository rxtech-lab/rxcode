import Foundation
import Testing
@testable import RxCodeCore

struct CodingAnalyticsLimitsTests {
    @Test func snapshotsSurviveRestartModelSwitchAndJSONExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("analytics.json")
        let store = CodingAnalyticsStore(url: url)
        let turn = UUID(), second = UUID(), project = UUID()
        let measuredAt = Date(timeIntervalSince1970: 100)
        let limits = RateLimitUsage(fiveHourPercent: 25, sevenDayPercent: 50, twentyFourHourPercent: 10,
                                   fiveHourResetsAt: measuredAt.addingTimeInterval(3600),
                                   sevenDayResetsAt: measuredAt.addingTimeInterval(86400),
                                   twentyFourHourResetsAt: measuredAt.addingTimeInterval(7200))
        let start = CodingUsageLimitSnapshot(phase: .start, provider: "codex", model: "gpt",
            status: .available, scope: "provider_account", source: "cached_provider_limits",
            measuredAt: measuredAt, rateLimits: limits, capturedAt: measuredAt)
        try await store.begin(threadID: "thread", projectID: project, turnID: turn, prompt: "Build it",
                              provider: "codex", clientID: nil, model: "gpt", usageLimits: start)
        var end = start
        end.phase = .end
        end.status = .stale
        try await store.finish(turnID: turn, threadID: "thread", usageLimits: end)
        let acp = CodingUsageLimitSnapshot(phase: .start, provider: "acp", acpClientID: "opencode", model: "model-2",
            status: .available, scope: "provider_reported_buckets", source: "acp-opencode", measuredAt: measuredAt,
            metrics: [.init("rolling", "5-hour usage", value: 60, unit: "%", detail: "Resets tomorrow")])
        try await store.begin(threadID: "thread", projectID: project, turnID: second, prompt: "Review it",
                              provider: "acp", clientID: "opencode", model: "model-2", usageLimits: acp)
        var unavailable = acp
        unavailable.phase = .result
        unavailable.status = .unavailable
        unavailable.metrics = []
        unavailable.reason = "No cached ACP usage limits."
        try await store.update(turnID: second, usageLimits: unavailable)
        let restored = CodingAnalyticsStore(url: url)
        let session = try #require(await restored.session("thread"))
        #expect(session.turns[0].usageLimits == [start, end])
        #expect(session.turns[1].usageLimits == [acp, unavailable])
        #expect(session.turns[0].usageLimits?.first?.rateLimits?.fiveHourResetsAt == limits.fiveHourResetsAt)
        #expect(session.turns[0].usageLimits?.first?.hasFiveHourLimit == true)
        let exported = try await restored.export()
        let json = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let sessions = try #require(json["sessions"] as? [[String: Any]])
        let turns = try #require(sessions.first?["turns"] as? [[String: Any]])
        let snapshots = try #require(turns.first?["usageLimits"] as? [[String: Any]])
        #expect(snapshots.first?["provider"] as? String == "codex")
        #expect(snapshots.first?["measuredAt"] as? String == "1970-01-01T00:01:40Z")
        #expect(snapshots.last?["status"] as? String == "stale")
        try await restored.deleteAll()
        try await restored.update(turnID: turn, usageLimits: start)
        #expect(try await restored.session("thread") == nil)
    }

    @Test func olderTurnsDecodeWithoutLimitSnapshots() throws {
        let data = Data("""
        {"id":"thread","projectID":"00000000-0000-0000-0000-000000000001","startedAt":0,
         "models":[],"turns":[{"id":"00000000-0000-0000-0000-000000000002",
         "prompts":["hello"],"startedAt":0,"usageSamples":0}]}
        """.utf8)
        let session = try JSONDecoder().decode(CodingAnalyticsSession.self, from: data)
        #expect(session.turns.first?.usageLimits == nil)
    }
}
