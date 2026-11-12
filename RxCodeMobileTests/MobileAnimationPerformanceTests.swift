import Foundation
import RxCodeCore
import RxCodeSync
import XCTest
@testable import RxCodeMobile

@MainActor
final class MobileAnimationPerformanceTests: XCTestCase {
    private func thread(_ id: String, project: UUID, branch: String = "main", time: Double) -> MobileThreadSummary {
        MobileThreadSummary(sessionId: id, projectId: project, branch: branch, title: id,
                            summary: "Summary", updatedAt: Date(timeIntervalSince1970: time))
    }

    func testGroupingKeepsLatestBriefingAndEveryThreadInDateOrder() throws {
        let project = UUID()
        let other = UUID()
        let latest = MobileBranchBriefing(projectId: project, branch: "main", briefing: "Latest",
                                         updatedAt: Date(timeIntervalSince1970: 10))
        let older = MobileBranchBriefing(projectId: project, branch: "main", briefing: "Older",
                                        updatedAt: Date(timeIntervalSince1970: 2))
        let groups = groupBriefings(briefings: [latest, older], threads: [
            thread("first", project: project, time: 1),
            thread("other", project: other, time: 4),
            thread("newest", project: project, time: 20),
            thread("branch", project: project, branch: "feature", time: 3)
        ])
        XCTAssertEqual(groups.count, 3)
        let main = try XCTUnwrap(groups.first)
        XCTAssertEqual(main.briefing, latest)
        XCTAssertEqual(main.threads.map(\.sessionId), ["newest", "first"])
        XCTAssertEqual(main.updatedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(groups.map(\.updatedAt), [20, 4, 3].map { Date(timeIntervalSince1970: $0) })
        let briefingOnly = groupBriefings(briefings: [latest, older], threads: [])
        XCTAssertEqual(briefingOnly.first?.briefing, latest)
        XCTAssertTrue(briefingOnly.first?.threads.isEmpty == true)
    }

    func testSharedGroupingRefreshesForChangedInputsAndProjectOrder() {
        let state = MobileAppState()
        let first = Project(name: "First", path: "/tmp/first")
        let second = Project(name: "Second", path: "/tmp/second")
        state.projects = [first, second]
        state.threadSummaries = [thread("second", project: second.id, time: 2)]
        XCTAssertEqual(state.briefingGroups.map(\.projectId), [second.id])
        state.threadSummaries.append(thread("first", project: first.id, time: 1))
        XCTAssertEqual(state.briefingGroups.map(\.projectId), [first.id, second.id])
        state.projects.reverse()
        XCTAssertEqual(state.briefingGroups.map(\.projectId), [second.id, first.id])
        state.branchBriefings = [MobileBranchBriefing(projectId: first.id, branch: "main", briefing: "New briefing",
                                                     updatedAt: Date(timeIntervalSince1970: 3))]
        XCTAssertEqual(state.briefingGroups.last?.briefing?.briefing, "New briefing")
        state.threadSummaries = []
        XCTAssertEqual(state.briefingGroups.map(\.projectId), [first.id])
        state.branchBriefings = []
        XCTAssertTrue(state.briefingGroups.isEmpty)
    }

    func testLargeSingleBranchKeepsAllThreads() {
        let project = UUID()
        let threads = (0..<5_000).map { thread("thread-\($0)", project: project, time: Double($0)) }
        let groups = groupBriefings(briefings: [], threads: threads)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.threads.map(\.sessionId), threads.reversed().map(\.sessionId))
    }

    func testTaskRunningIndexTracksStreamingChangesAndRemoval() {
        let state = MobileAppState()
        let project = UUID()
        let task = ProjectTask(projectId: project, title: "Task")
        state.taskBoardsByProject[project] = MobileTaskBoardSnapshot(
            projectID: project, board: TaskBoard(), taskSessionIDs: [task.id.uuidString: "chat"]
        )
        state.sessions = [SessionSummary(id: "chat", projectId: project, title: "Chat",
                                         updatedAt: .now, isPinned: false, isArchived: false)]
        XCTAssertFalse(state.isTaskAgentRunning(task))
        state.updateSessionStreamingFlag(sessionID: "chat", isStreaming: true)
        XCTAssertTrue(state.isTaskAgentRunning(task))
        state.updateSessionStreamingFlag(sessionID: "chat", isStreaming: false)
        XCTAssertFalse(state.isTaskAgentRunning(task))
        state.updateSessionStreamingFlag(sessionID: "chat", isStreaming: true)
        state.sessions = []
        XCTAssertFalse(state.isTaskAgentRunning(task))
    }

    func testTaskCacheRoundTripsOnBackgroundExecutor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("task-cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = Project(name: "Cached project", path: "/tmp/cached-project")
        let cache = MobileTaskCache(projects: [project], boards: [
            MobileTaskBoardSnapshot(projectID: project.id, board: TaskBoard(), taskSessionIDs: ["task": "chat"])
        ])
        let loaded = try await Task.detached {
            // This closure must compile and execute without hopping to MainActor.
            XCTAssertFalse(Thread.isMainThread)
            try cache.save(to: url)
            return MobileTaskCache.load(from: url)
        }.value
        XCTAssertEqual(loaded?.projects.map(\.id), [project.id])
        XCTAssertEqual(loaded?.boards.first?.taskSessionIDs, ["task": "chat"])
    }
}
