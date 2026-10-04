import Foundation
import Testing
@testable import RxCodeCore

@Suite("Scheduled task runs")
struct ScheduledTaskRunTests {

    @Test("A run survives a round trip")
    func roundTrips() throws {
        let run = ScheduledTaskRun(
            taskId: UUID(), projectId: UUID(), sessionKey: "abc", trigger: .manual,
            status: .succeeded, finishedAt: .now, summary: "Done"
        )
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(ScheduledTaskRun.self, from: data)
        #expect(decoded == run)
    }

    @Test("Unknown or missing values fall back")
    func tolerantDecoding() throws {
        let json = """
        {"id":"\(UUID().uuidString)","taskId":"\(UUID().uuidString)","status":"exploded"}
        """
        let decoded = try JSONDecoder().decode(ScheduledTaskRun.self, from: Data(json.utf8))
        #expect(decoded.status == .interrupted)
        #expect(decoded.trigger == .schedule)
        #expect(decoded.sessionKey == nil)
    }

    @Test("Runs still running on load become interrupted")
    func restoredMarksInterrupted() {
        let taskId = UUID()
        let runs = ScheduledTaskRun.restored([
            ScheduledTaskRun(taskId: taskId, status: .running),
            ScheduledTaskRun(taskId: taskId, status: .succeeded),
        ])
        #expect(runs.map(\.status) == [.interrupted, .succeeded])
    }

    @Test("Pruning keeps the newest runs of each task")
    func prunedPerTask() {
        let a = UUID(), b = UUID()
        let base = Date(timeIntervalSince1970: 0)
        let runs = (0..<5).map { ScheduledTaskRun(taskId: a, startedAt: base.addingTimeInterval(Double($0))) }
            + [ScheduledTaskRun(taskId: b, startedAt: base)]
        let pruned = ScheduledTaskRun.pruned(runs, limit: 2)
        #expect(pruned.filter { $0.taskId == a }.map(\.startedAt) == [base.addingTimeInterval(4), base.addingTimeInterval(3)])
        #expect(pruned.contains { $0.taskId == b })
    }

    @Test("Summaries are trimmed and capped")
    func summary() {
        #expect(ScheduledTaskRun.makeSummary("  \n ") == nil)
        #expect(ScheduledTaskRun.makeSummary(" hi ") == "hi")
        let long = String(repeating: "x", count: ScheduledTaskRun.summaryLimit + 10)
        #expect(ScheduledTaskRun.makeSummary(long)?.count == ScheduledTaskRun.summaryLimit + 1)
    }
}
