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
