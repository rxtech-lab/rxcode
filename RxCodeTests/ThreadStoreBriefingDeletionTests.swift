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
        XCTAssertNil(store.branchBriefingItem(projectId: projectId, branch: "main"))
        XCTAssertEqual(store.branchBriefingItem(projectId: projectId, branch: "feature")?.briefing, "Feature briefing")
        XCTAssertEqual(store.threadSummaryItems(projectId: projectId, branch: "main").map(\.summary), ["Still here"])
        XCTAssertFalse(try store.deleteBranchBriefing(projectId: projectId, branch: "main"))
    }
}
