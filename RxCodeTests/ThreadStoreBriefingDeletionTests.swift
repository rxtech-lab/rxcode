import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class ThreadStoreBriefingDeletionTests: XCTestCase {
    // Keep the in-memory SwiftData container alive through XCTest teardown.
    private static var retainedStores: [ThreadStore] = []

    func testDeletingBranchBriefingPreservesThreadSummariesAndOtherBranches() throws {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        let projectId = UUID()
        store.upsertBranchBriefing(projectId: projectId, branch: "main", briefing: "Main briefing")
        store.upsertBranchBriefing(projectId: projectId, branch: "feature", briefing: "Feature briefing")
        store.context.insert(ThreadSummaryRecord(
            sessionId: "thread-1",
            projectId: projectId,
            branch: "main",
            title: "Thread",
            summary: "Still here",
            updatedAt: .now
        ))
        store.save()

        XCTAssertTrue(try store.deleteBranchBriefing(projectId: projectId, branch: "main"))
        XCTAssertTrue(store.branchBriefingItems(projectId: projectId, branch: "main").isEmpty)
        XCTAssertEqual(store.branchBriefingItems(projectId: projectId, branch: "feature").map(\.briefing), ["Feature briefing"])
        XCTAssertEqual(store.threadSummaryItems(projectId: projectId, branch: "main").map(\.summary), ["Still here"])
        XCTAssertFalse(try store.deleteBranchBriefing(projectId: projectId, branch: "main"))
    }

    func testBranchBriefingsAreStoredPerDay() throws {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        let projectId = UUID()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        store.upsertBranchBriefing(projectId: projectId, branch: "main", day: yesterday, briefing: "Yesterday")
        store.upsertBranchBriefing(projectId: projectId, branch: "main", day: today, briefing: "Today v1")
        store.upsertBranchBriefing(projectId: projectId, branch: "main", day: today, briefing: "Today v2")

        let items = store.branchBriefingItems(projectId: projectId, branch: "main")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(store.branchBriefingItem(projectId: projectId, branch: "main", day: today)?.briefing, "Today v2")
        XCTAssertEqual(store.branchBriefingItem(projectId: projectId, branch: "main", day: yesterday)?.briefing, "Yesterday")

        // Deleting one day leaves the other day in place.
        let todayItem = try XCTUnwrap(store.branchBriefingItem(projectId: projectId, branch: "main", day: today))
        XCTAssertTrue(try store.deleteBranchBriefing(id: todayItem.id))
        XCTAssertEqual(store.branchBriefingItems(projectId: projectId, branch: "main").map(\.briefing), ["Yesterday"])
    }

    func testCombinedBranchBriefingJoinsDaysOldestFirst() {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        let projectId = UUID()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        store.upsertBranchBriefing(projectId: projectId, branch: "main", day: today, briefing: "Second day")
        XCTAssertEqual(store.combinedBranchBriefing(projectId: projectId, branch: "main"), "Second day")

        store.upsertBranchBriefing(projectId: projectId, branch: "main", day: yesterday, briefing: "First day")
        let combined = try? XCTUnwrap(store.combinedBranchBriefing(projectId: projectId, branch: "main"))
        let first = combined?.range(of: "First day")
        let second = combined?.range(of: "Second day")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!.lowerBound, second!.lowerBound)
    }

    func testThreadSummaryTakesChatCreationDate() {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        let projectId = UUID()
        let created = Date(timeIntervalSinceNow: -3 * 86_400)
        store.upsertThreadSummary(
            sessionId: "thread-1",
            projectId: projectId,
            branch: "main",
            title: "Thread",
            summary: "Summary",
            createdAt: created
        )
        XCTAssertEqual(store.threadSummaryItem(sessionId: "thread-1")?.createdAt, created)
    }
}
