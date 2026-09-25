import XCTest
import RxCodeCore
@testable import RxCode

/// Covers the bulk index loaders backing the sidebar's per-row state. These
/// replaced per-row `fileEditCount` / `fetchTodoSnapshot` calls, which put a
/// synchronous SQLite query on the main thread for every visible thread on every
/// SwiftUI view-graph update.
@MainActor
final class ThreadStoreSidebarIndexTests: XCTestCase {

    // `ThreadStore` is `@MainActor`, so its synthesized deinit hops executors via
    // the Swift concurrency runtime — which double-frees when a local store
    // deallocates at a test's return. Retain every store for the test process so
    // that deinit never runs mid-run (see `ThreadStoreHookCardTests`).
    private static var retainedStores: [ThreadStore] = []
    private func makeStore() -> ThreadStore {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        return store
    }

    private func hunk() -> PreviewFile.EditHunk {
        PreviewFile.EditHunk(oldString: "before", newString: "after")
    }

    private func todo(_ id: Int, _ content: String, _ status: TodoItem.Status) -> TodoItem {
        TodoItem(id: id, content: content, activeForm: content, status: status)
    }

    func testSessionIdsWithFileEditsReturnsEverySessionThatRecordedAnEdit() {
        let store = makeStore()
        store.appendFileEdit(
            sessionId: "session-a",
            path: "/tmp/one.swift",
            hunks: [hunk()],
            containsWrite: true,
            originalContent: "before",
            modifiedContent: "after"
        )
        // A second path in the same session must not produce a duplicate entry.
        store.appendFileEdit(
            sessionId: "session-a",
            path: "/tmp/two.swift",
            hunks: [hunk()],
            containsWrite: false
        )
        store.appendFileEdit(
            sessionId: "session-b",
            path: "/tmp/three.swift",
            hunks: [hunk()],
            containsWrite: false
        )

        let ids = store.sessionIdsWithFileEdits()

        XCTAssertEqual(ids, ["session-a", "session-b"])
    }

    /// The loader fetches only `sessionId` for performance. Guard against that
    /// partial fetch silently yielding nothing, which would hide "Commit Files"
    /// on every thread rather than fail loudly.
    func testSessionIdsWithFileEditsIsNotEmptiedByThePartialPropertyFetch() {
        let store = makeStore()
        store.appendFileEdit(
            sessionId: "session-only",
            path: "/tmp/file.swift",
            hunks: [hunk()],
            containsWrite: true,
            originalContent: String(repeating: "x", count: 4096),
            modifiedContent: String(repeating: "y", count: 4096)
        )

        XCTAssertEqual(store.sessionIdsWithFileEdits(), ["session-only"])
        XCTAssertEqual(store.fileEditCount(sessionId: "session-only"), 1)
    }

    func testSessionIdsWithFileEditsIsEmptyWithoutAnyEdits() {
        XCTAssertTrue(makeStore().sessionIdsWithFileEdits().isEmpty)
    }

    func testLoadTodoProgressBySessionMirrorsPerSessionSnapshots() {
        let store = makeStore()
        store.upsertTodoSnapshot(sessionId: "session-a", items: [
            todo(1, "done", .completed),
            todo(2, "working", .inProgress),
            todo(3, "queued", .pending)
        ])
        store.upsertTodoSnapshot(sessionId: "session-b", items: [
            todo(1, "done", .completed)
        ])

        let progress = store.loadTodoProgressBySession()

        XCTAssertEqual(progress["session-a"], ChatTodoProgress(done: 1, total: 3, inProgress: true))
        XCTAssertEqual(progress["session-b"], ChatTodoProgress(done: 1, total: 1, inProgress: false))
        XCTAssertNil(progress["session-missing"])
    }

    func testLoadTodoProgressBySessionReflectsLaterUpserts() {
        let store = makeStore()
        store.upsertTodoSnapshot(sessionId: "session", items: [
            todo(1, "a", .pending),
            todo(2, "b", .pending)
        ])
        store.upsertTodoSnapshot(sessionId: "session", items: [
            todo(1, "a", .completed),
            todo(2, "b", .completed)
        ])

        XCTAssertEqual(
            store.loadTodoProgressBySession()["session"],
            ChatTodoProgress(done: 2, total: 2, inProgress: false)
        )
    }
}
