import XCTest
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCode

@MainActor
final class BriefingThreadRowTests: XCTestCase {

    func testInProgressThreadShowsStatusBadge() throws {
        let row = BriefingThreadRow(
            item: item(title: "Streaming thread"),
            isInProgress: true,
            todoProgress: ChatTodoProgress(done: 1, total: 3, inProgress: true),
            onSelect: {}
        )

        let labels = try row.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains("In progress"),
            "Briefing thread rows must surface active thread status. Labels: \(labels)"
        )
    }

    func testIdleThreadDoesNotShowInProgressBadge() throws {
        let row = BriefingThreadRow(
            item: item(title: "Finished thread"),
            isInProgress: false,
            todoProgress: nil,
            onSelect: {}
        )

        let labels = try row.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertFalse(
            labels.contains("In progress"),
            "Finished briefing thread rows should keep the compact updated-at label instead of an active status. Labels: \(labels)"
        )
    }

    func testTappingThreadRowSelectsThread() throws {
        var didSelect = false
        let row = BriefingThreadRow(
            item: item(title: "Selectable thread"),
            isInProgress: true,
            todoProgress: nil,
            onSelect: { didSelect = true }
        )

        try row.inspect().find(ViewType.Button.self).tap()

        XCTAssertTrue(didSelect, "Tapping the briefing thread row must still open the thread.")
    }

    private func item(title: String) -> ThreadSummaryItem {
        ThreadSummaryItem(
            sessionId: UUID().uuidString,
            projectId: UUID(),
            branch: "main",
            title: title,
            summary: "Summary",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
