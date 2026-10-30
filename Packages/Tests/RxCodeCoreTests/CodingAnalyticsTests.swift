import Foundation
import Testing
@testable import RxCodeCore

struct CodingAnalyticsTests {
    private func makeStore() -> (CodingAnalyticsStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("analytics.json")
        return (CodingAnalyticsStore(url: url), url)
    }

    @Test func recordsModelSwitchesPromptsTokensAndRatingAcrossRestart() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = UUID(), second = UUID(), project = UUID()
        let start = Date(timeIntervalSince1970: 100)
        try await store.begin(threadID: "pending", projectID: project, turnID: first, prompt: "Fix the bug",
                              provider: "claudeCode", clientID: nil, model: "sonnet", now: start)
        try await store.update(turnID: first, prompt: "Keep the tests")
        try await store.update(turnID: first, model: "claude-sonnet", usage: .init(
            inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 3, cacheReadInputTokens: 4))
        try await store.redirect(from: "pending", to: "thread")
        try await store.finish(turnID: first, threadID: "thread", now: start.addingTimeInterval(10))
        try await store.begin(threadID: "thread", projectID: project, turnID: second, prompt: "Review it",
                              provider: "acp", clientID: "opencode", model: "gpt", now: start.addingTimeInterval(20))
        try await store.finish(turnID: second, threadID: "thread", now: start.addingTimeInterval(25))
        try await store.rate(threadID: "thread", rating: .good)
        let restored = CodingAnalyticsStore(url: url)
        let session = try #require(await restored.session("thread"))
        #expect(session.turns.count == 2)
        #expect(session.turns[0].prompts == ["Fix the bug", "Keep the tests"])
        #expect(session.models.map(\.provider) == ["claudeCode", "claudeCode", "acp"])
        #expect(session.models.last?.acpClientID == "opencode")
        #expect(session.totalReportedTokens == 37)
        #expect(session.turns[1].inputTokens == nil)
        #expect(session.rating == .good)
        #expect(session.elapsedSeconds == 25)
        #expect(session.activeSeconds == 15)
        let data = try await restored.export()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect((json["sessions"] as? [[String: Any]])?.count == 1)
        let exported = try #require((json["sessions"] as? [[String: Any]])?.first)
        #expect(exported["activeSeconds"] as? Double == 15)
        #expect(exported["elapsedSeconds"] as? Double == 25)
        #expect(exported["totalReportedTokens"] as? Int == 37)
        #expect(exported["id"] as? String == "thread")
        try await restored.rate(threadID: "thread", rating: nil)
        #expect(try await restored.session("thread")?.rating == nil)
    }

    @Test func deletionRejectsLateStreamEventsAndAllowsNewRecording() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let turn = UUID(), project = UUID()
        try await store.begin(threadID: "thread", projectID: project, turnID: turn, prompt: "Private prompt",
                              provider: "codex", clientID: nil, model: "gpt")
        try await store.deleteAll()
        try await store.update(turnID: turn, prompt: "Late steer", usage: .init(
            inputTokens: 1, outputTokens: 1, cacheCreationInputTokens: 0, cacheReadInputTokens: 0))
        try await store.finish(turnID: turn, threadID: "thread")
        try await store.rate(threadID: "thread", rating: .bad)
        #expect(try await store.session("thread") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await store.begin(threadID: "thread", projectID: project, turnID: UUID(), prompt: "New prompt",
                              provider: "codex", clientID: nil, model: "gpt")
        #expect(try await store.session("thread")?.turns.count == 1)
        #expect(try await store.session("thread")?.totalReportedTokens == nil)
    }

    @Test func corruptedDataIsReportedInsteadOfOverwritten() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: url)
        await #expect(throws: (any Error).self) {
            try await store.begin(threadID: "thread", projectID: UUID(), turnID: UUID(), prompt: "hello",
                                  provider: "codex", clientID: nil, model: nil)
        }
        #expect(try Data(contentsOf: url) == corrupt)
        try await store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func internalTurnsOnlyExtendAnExistingRecordedSession() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = UUID(), first = UUID(), followup = UUID()
        try await store.begin(threadID: "unrecorded", projectID: project, turnID: UUID(), prompt: nil,
                              provider: "claudeCode", clientID: nil, model: "sonnet")
        #expect(try await store.session("unrecorded") == nil)
        try await store.begin(threadID: "thread", projectID: project, turnID: first, prompt: "Implement this",
                              provider: "claudeCode", clientID: nil, model: "sonnet")
        try await store.finish(turnID: first, threadID: "thread")
        try await store.begin(threadID: "thread", projectID: project, turnID: followup, prompt: nil,
                              provider: "claudeCode", clientID: nil, model: "sonnet")
        try await store.update(turnID: followup, usage: .init(inputTokens: 5, outputTokens: 2,
                                                            cacheCreationInputTokens: 0, cacheReadInputTokens: 0))
        try await store.finish(turnID: followup, threadID: "thread")
        let session = try #require(await store.session("thread"))
        #expect(session.turns.count == 2)
        #expect(session.turns[1].prompts.isEmpty)
        #expect(session.totalReportedTokens == 7)
    }

    @Test func stoppingRecordingClosesTimingAndMarksPartialTurn() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let turn = UUID(), start = Date(timeIntervalSince1970: 100)
        try await store.begin(threadID: "thread", projectID: UUID(), turnID: turn, prompt: "hello",
                              provider: "codex", clientID: nil, model: "gpt", now: start)
        try await store.stopRecording(turnIDs: [turn], now: start.addingTimeInterval(5))
        let session = try #require(await store.session("thread"))
        #expect(session.activeSeconds == 5)
        #expect(session.turns.first?.recordingStopped == true)
    }

    @Test func overlappingTurnsKeepTheirModelProviderAndLatestEndTime() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = UUID(), new = UUID(), project = UUID()
        let start = Date(timeIntervalSince1970: 100)
        try await store.begin(threadID: "pending", projectID: project, turnID: old, prompt: "first",
                              provider: "claudeCode", clientID: nil, model: "sonnet", now: start)
        try await store.begin(threadID: "thread", projectID: project, turnID: new, prompt: "second",
                              provider: "codex", clientID: nil, model: "gpt", now: start.addingTimeInterval(5))
        try await store.redirect(from: "pending", to: "thread")
        try await store.update(turnID: old, model: "claude-sonnet")
        #expect(try await store.session("thread")?.models.last?.provider == "claudeCode")
        try await store.finish(turnID: new, threadID: "thread", now: start.addingTimeInterval(20))
        #expect(try await store.session("thread")?.endedAt == nil)
        try await store.finish(turnID: old, threadID: "thread", now: start.addingTimeInterval(10))
        #expect(try await store.session("thread")?.endedAt == start.addingTimeInterval(20))
    }

}
