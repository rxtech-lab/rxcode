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

    func testPlanOnlyDayGroupsByLastActivityAndUpdatesCachedTimeline() throws {
        let state = MobileAppState()
        let project = Project(name: "Plans", path: "/tmp/plans")
        state.projects = [project]
        let original = Date(timeIntervalSince1970: 3600)
        let revised = original.addingTimeInterval(2 * 86_400)
        let plan = CodingPlanActivity(
            id: UUID(), threadID: "planning", projectID: project.id, title: "Extension support", goal: "",
            branch: "main", createdAt: original, updatedAt: revised, planningStatus: "ready",
            implementationStatus: "unknown", implementationEvidence: "", implementationThreadID: nil,
            currentVersionID: UUID(), currentVersionTitle: "Final design", approvedVersionID: nil,
            versionCount: 3, featureExcerpt: "Discover extensions"
        )
        XCTAssertTrue(state.briefingGroups.isEmpty)
        state.briefingPlans = [plan]
        let group = try XCTUnwrap(state.briefingGroups.first)
        XCTAssertEqual(group.day, Calendar.current.startOfDay(for: revised))
        XCTAssertEqual(group.plans, [plan])
        XCTAssertTrue(group.threads.isEmpty)
        XCTAssertNil(group.briefing)
        state.briefingPlans = []
        XCTAssertTrue(state.briefingGroups.isEmpty)
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

    func testGroupingSplitsBranchWorkByDayLikeDesktop() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let project = UUID()
        let day1 = Date(timeIntervalSince1970: 86_400 * 10)
        let day2 = day1.addingTimeInterval(86_400)
        let dated = MobileBranchBriefing(projectId: project, branch: "main", briefing: "Day 1",
                                        updatedAt: day1.addingTimeInterval(3_600), day: day1)
        let legacy = MobileBranchBriefing(projectId: project, branch: "main", briefing: "Legacy",
                                         updatedAt: day1.addingTimeInterval(7_200))
        let threads = [
            MobileThreadSummary(sessionId: "a", projectId: project, branch: "main", title: "a", summary: "",
                                updatedAt: day2.addingTimeInterval(600), createdAt: day1.addingTimeInterval(60)),
            MobileThreadSummary(sessionId: "b", projectId: project, branch: "main", title: "b", summary: "",
                                updatedAt: day2.addingTimeInterval(900), createdAt: day2.addingTimeInterval(300)),
        ]
        let groups = groupBriefings(briefings: [legacy, dated], threads: threads, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        let first = try XCTUnwrap(groups.first { $0.day == day1 })
        // A dated briefing wins its day over a legacy whole-branch briefing.
        XCTAssertEqual(first.briefing?.briefing, "Day 1")
        // Chats belong to the day they were created, not last updated.
        XCTAssertEqual(first.threads.map(\.sessionId), ["a"])
        XCTAssertEqual(first.createdAt, day1.addingTimeInterval(60))
        let second = try XCTUnwrap(groups.first { $0.day == day2 })
        XCTAssertNil(second.briefing)
        XCTAssertEqual(second.threads.map(\.sessionId), ["b"])
        XCTAssertNotEqual(first.key, second.key)
    }

    func testTimelineFiltersAndDaySections() {
        let project = UUID()
        let other = UUID()
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let lastWeek = calendar.date(byAdding: .day, value: -10, to: today)!
        let threads = [
            thread("today-main", project: project, time: today.addingTimeInterval(60).timeIntervalSince1970),
            thread("today-feature", project: project, branch: "feature",
                   time: today.addingTimeInterval(120).timeIntervalSince1970),
            thread("old-other", project: other, time: lastWeek.addingTimeInterval(60).timeIntervalSince1970),
        ]
        let groups = groupBriefings(briefings: [], threads: threads)
        let document = MobileBriefingDocument(id: UUID(), title: "Doc", format: "markdown", projectId: other,
                                              createdAt: today.addingTimeInterval(30), updatedAt: today)
        var filters = MobileBriefingFilters()
        let all = filters.entries(groups: groups, documents: [document], currentBranches: [project: "main"],
                                  projects: [], now: now)
        XCTAssertEqual(all.count, 4)
        let sections = MobileBriefingFilters.daySections(all)
        XCTAssertEqual(sections.map(\.day), [today, lastWeek])
        XCTAssertEqual(sections.first?.entries.count, 3)

        filters.currentBranchOnly = true
        XCTAssertEqual(filters.entries(groups: groups, documents: [], currentBranches: [project: "main"],
                                       projects: [], now: now).count, 2)
        filters = MobileBriefingFilters(kind: .document)
        XCTAssertEqual(filters.entries(groups: groups, documents: [document], currentBranches: [:],
                                       projects: [], now: now).map(\.id), ["document::\(document.id.uuidString)"])
        filters = MobileBriefingFilters(timeRange: .week)
        XCTAssertEqual(filters.entries(groups: groups, documents: [], currentBranches: [:],
                                       projects: [], now: now).count, 2)
        filters = MobileBriefingFilters(projectIds: [other])
        XCTAssertEqual(filters.entries(groups: groups, documents: [document], currentBranches: [:],
                                       projects: [], now: now).count, 2)
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

    func testTimelineRefreshesAfterBranchDocumentAndThreadChanges() {
        let state = MobileAppState()
        let project = UUID()
        let now = Date()
        state.threadSummaries = [thread("main", project: project, time: now.timeIntervalSince1970)]
        state.projectBranches = [project: "main"]
        let filters = MobileBriefingFilters(currentBranchOnly: true)
        XCTAssertEqual(state.briefingSections(filters: filters, now: now).first?.entries.count, 1)

        // Unrelated transport updates can reuse the timeline.
        state.desktopHostMetrics = nil
        XCTAssertEqual(state.briefingSections(filters: filters, now: now).first?.entries.count, 1)
        state.projectBranches = [project: "feature"]
        XCTAssertTrue(state.briefingSections(filters: filters, now: now).isEmpty)
        state.briefingDocuments = [MobileBriefingDocument(id: UUID(), title: "Document", format: "markdown",
                                                        projectId: project, createdAt: now, updatedAt: now)]
        XCTAssertEqual(state.briefingSections(filters: filters, now: now).first?.entries.count, 1)
        state.threadSummaries = [thread("feature", project: project, branch: "feature", time: now.timeIntervalSince1970)]
        XCTAssertEqual(state.briefingSections(filters: filters, now: now).first?.entries.count, 2)
        state.briefingDocuments = []
        state.threadSummaries = []
        XCTAssertTrue(state.briefingSections(filters: filters, now: now).isEmpty)
    }

    func testTimelineDateFiltersExpireWithoutSourceChanges() {
        let state = MobileAppState()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: .now)
        let created = day.addingTimeInterval(3600)
        let project = UUID()
        state.threadSummaries = [thread("old", project: project, time: created.timeIntervalSince1970)]
        let filters = MobileBriefingFilters(timeRange: .today)
        XCTAssertEqual(state.briefingSections(filters: filters, now: created).count, 1)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        XCTAssertTrue(state.briefingSections(filters: filters, now: tomorrow).isEmpty)

        let expiry = calendar.date(byAdding: .day, value: 7, to: created)!
        let weekly = MobileBriefingFilters(timeRange: .week)
        XCTAssertEqual(state.briefingSections(filters: weekly, now: expiry.addingTimeInterval(-1)).count, 1)
        XCTAssertEqual(state.briefingSections(filters: weekly, now: expiry).count, 1)
        XCTAssertTrue(state.briefingSections(filters: weekly, now: expiry.addingTimeInterval(1)).isEmpty)
    }

    func testMobileFlowcyUsesCloudInEveryBuildConfiguration() {
        XCTAssertEqual(FlowcyAPI.defaultBaseURL.absoluteString, "https://www.flowcy.dev")
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
