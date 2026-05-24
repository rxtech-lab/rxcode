import XCTest
import RxCodeCore

@MainActor
final class ThreadStoreThreadSummaryTests: XCTestCase {

    func testTitleSeedRecordUsesEmptySummary() {
        let sessionId = "session-title-created"
        let projectId = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let item = ThreadSummaryItem.titleSeed(
            sessionId: sessionId,
            projectId: projectId,
            branch: "mcp-server",
            title: "Panel Width Reset",
            updatedAt: date
        )

        XCTAssertEqual(item.sessionId, sessionId)
        XCTAssertEqual(item.projectId, projectId)
        XCTAssertEqual(item.branch, "mcp-server")
        XCTAssertEqual(item.title, "Panel Width Reset")
        XCTAssertEqual(item.summary, "")
        XCTAssertEqual(item.updatedAt, date)
    }

    func testFinishSummaryUpdatesTitleSeedRecord() {
        let sessionId = "session-finished"
        let projectId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_060)

        let seed = ThreadSummaryItem.titleSeed(
            sessionId: sessionId,
            projectId: projectId,
            branch: "mcp-server",
            title: "Mobile Briefing",
            updatedAt: createdAt
        )
        let finished = ThreadSummaryItem(
            sessionId: seed.sessionId,
            projectId: seed.projectId,
            branch: seed.branch,
            title: seed.title,
            summary: "The briefing now includes live titled threads.",
            updatedAt: finishedAt
        )

        XCTAssertEqual(finished.sessionId, sessionId)
        XCTAssertEqual(finished.title, "Mobile Briefing")
        XCTAssertEqual(finished.summary, "The briefing now includes live titled threads.")
        XCTAssertEqual(finished.updatedAt, finishedAt)
    }

    func testTitleUpdatePreservesExistingGeneratedSummary() {
        let sessionId = "session-renamed-after-summary"
        let projectId = UUID()
        let summaryAt = Date(timeIntervalSince1970: 1_700_000_000)
        let renameAt = Date(timeIntervalSince1970: 1_700_000_120)

        let existing = ThreadSummaryItem(
            sessionId: sessionId,
            projectId: projectId,
            branch: "main",
            title: "Old Title",
            summary: "Existing generated summary.",
            updatedAt: summaryAt
        )
        let updated = existing.updatingTitle(
            projectId: projectId,
            branch: "mcp-server",
            title: "New Title",
            updatedAt: renameAt
        )

        XCTAssertEqual(updated.branch, "mcp-server")
        XCTAssertEqual(updated.title, "New Title")
        XCTAssertEqual(updated.summary, "Existing generated summary.")
        XCTAssertEqual(updated.updatedAt, renameAt)
    }
}
