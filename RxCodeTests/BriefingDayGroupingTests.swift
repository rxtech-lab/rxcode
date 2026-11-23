import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class BriefingDayGroupingTests: XCTestCase {
    private let calendar = Calendar.current
    private let projectId = UUID()

    private func thread(_ id: String, branch: String = "main", createdAt: Date) -> ThreadSummaryItem {
        ThreadSummaryItem(
            sessionId: id,
            projectId: projectId,
            branch: branch,
            title: id,
            summary: "summary \(id)",
            updatedAt: createdAt.addingTimeInterval(60),
            createdAt: createdAt
        )
    }

    func testBranchWorkedAcrossDaysSplitsIntoOneGroupPerDay() {
        let today = calendar.startOfDay(for: .now).addingTimeInterval(3_600)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let groups = BriefingView.dayGroups(
            briefings: [
                BranchBriefingItem(projectId: projectId, branch: "main", day: calendar.startOfDay(for: today),
                                   briefing: "Today", updatedAt: today),
                BranchBriefingItem(projectId: projectId, branch: "main", day: calendar.startOfDay(for: yesterday),
                                   briefing: "Yesterday", updatedAt: yesterday)
            ],
            threads: [
                thread("a", createdAt: yesterday),
                thread("b", createdAt: today),
                thread("c", createdAt: today.addingTimeInterval(600))
            ]
        )
        .sorted { $0.day > $1.day }

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].briefing?.briefing, "Today")
        XCTAssertEqual(Set(groups[0].threadSummaries.map(\.sessionId)), ["b", "c"])
        XCTAssertEqual(groups[1].briefing?.briefing, "Yesterday")
        XCTAssertEqual(groups[1].threadSummaries.map(\.sessionId), ["a"])
        for group in groups {
            XCTAssertTrue(calendar.isDate(group.createdAt, inSameDayAs: group.day))
        }
    }

    func testSavedPlanAppearsWithoutThreadSummaryAndFeedsBranchPromptOnce() async throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let project = Project(id: projectId, name: "Briefing project", path: "/tmp/briefing-test")
        state.projects = [project]

        let planner = AgentModel(provider: .codex, id: "planner", displayName: "Planner")
        var plan = CodingPlan(id: UUID(), goal: "Support extension discovery", source: "",
                              configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "Explore app extensions.")
        plan.finish(.reconcile, text: "Discover supported extensions in Settings.")
        let session = ChatSession(id: plan.id.uuidString, projectId: projectId, title: plan.goal,
                                  messages: [], worktreeBranch: "feature/plugins", threadLabel: "Plan")
        state.threadStore.upsert(session.summary)
        try state.threadStore.saveCodingPlan(plan)
        await state.briefingPlansRefresh?.value

        let saved = try XCTUnwrap(state.briefingPlans.first(where: { $0.id == plan.id }))
        let groups = BriefingView.dayGroups(briefings: [], threads: [], plans: [saved])
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.branch, "feature/plugins")
        XCTAssertEqual(group.day, calendar.startOfDay(for: saved.updatedAt))
        XCTAssertNil(group.briefing)
        XCTAssertEqual(group.plans.map(\.id), [plan.id])
        XCTAssertEqual(saved.versionCount, 2)
        XCTAssertEqual(saved.planningStatusLabel, "Ready")
        XCTAssertEqual(saved.implementationStatusLabel, "Unimplemented")

        let prompt = OpenAISummarizationService.branchBriefingPrompt(threadSummaries: [], plans: group.plans)
        XCTAssertEqual(prompt.components(separatedBy: plan.id.uuidString).count, 2)
        XCTAssertTrue(prompt.contains("Discover supported extensions in Settings."))
        XCTAssertTrue(prompt.contains(saved.briefingDescription))
        XCTAssertFalse(prompt.contains("Explore app extensions."))

        state.threadStore.delete(id: session.id)
        await state.briefingPlansRefresh?.value
        XCTAssertFalse(state.briefingPlans.contains(where: { $0.id == plan.id }))
    }

    func testLegacyBriefingDoesNotReplaceDayBriefing() {
        let today = calendar.startOfDay(for: .now).addingTimeInterval(3_600)
        let groups = BriefingView.dayGroups(
            briefings: [
                BranchBriefingItem(projectId: projectId, branch: "main", briefing: "Legacy", updatedAt: today),
                BranchBriefingItem(projectId: projectId, branch: "main", day: calendar.startOfDay(for: today),
                                   briefing: "Dated", updatedAt: today)
            ],
            threads: []
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.briefing?.briefing, "Dated")
    }

    func testLegacyBriefingShowsOnItsLastUpdatedDay() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let groups = BriefingView.dayGroups(
            briefings: [
                BranchBriefingItem(projectId: projectId, branch: "main", briefing: "Legacy", updatedAt: yesterday,
                                   createdAt: calendar.date(byAdding: .day, value: -5, to: .now))
            ],
            threads: []
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.day, calendar.startOfDay(for: yesterday))
        XCTAssertTrue(calendar.isDate(groups[0].createdAt, inSameDayAs: yesterday))
    }
}
