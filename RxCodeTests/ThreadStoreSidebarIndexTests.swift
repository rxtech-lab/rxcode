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

    func testFileEditPresenceDistinguishesPlanOnlySessions() {
        let store = makeStore()
        store.appendFileEdit(
            sessionId: "session-a",
            path: "/tmp/.claude/plans/plan.md",
            hunks: [hunk()],
            containsWrite: true
        )
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
            path: "/tmp/.claude/plans/other.md",
            hunks: [hunk()],
            containsWrite: false
        )

        let presence = ThreadStore.fileEditPresence(in: store.context)

        XCTAssertEqual(presence, ["session-a": .previewable, "session-b": .planOnly])
    }

    /// The loader fetches only session IDs and paths for performance. Guard against that
    /// partial fetch silently yielding nothing, which would hide "Commit Files"
    /// on every thread rather than fail loudly.
    func testFileEditPresenceSurvivesThePartialPropertyFetch() {
        let store = makeStore()
        store.appendFileEdit(
            sessionId: "session-only",
            path: "/tmp/file.swift",
            hunks: [hunk()],
            containsWrite: true,
            originalContent: String(repeating: "x", count: 4096),
            modifiedContent: String(repeating: "y", count: 4096)
        )

        XCTAssertEqual(ThreadStore.fileEditPresence(in: store.context), ["session-only": .previewable])
        XCTAssertEqual(store.fileEditCount(sessionId: "session-only"), 1)
    }

    func testFileEditPresenceIsEmptyWithoutAnyEdits() {
        let store = makeStore()
        XCTAssertTrue(ThreadStore.fileEditPresence(in: store.context).isEmpty)
    }

    func testLoadTodoProgressBySessionMirrorsPerSessionSnapshots() throws {
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
        let first = try XCTUnwrap(store.fetchTodoSnapshot(sessionId: "session-a"))
        let second = try XCTUnwrap(store.fetchTodoSnapshot(sessionId: "session-b"))

        XCTAssertEqual(progress["session-a"], ChatTodoProgress(done: 1, total: 3, inProgress: true, updatedAt: first.updatedAt))
        XCTAssertEqual(progress["session-b"], ChatTodoProgress(done: 1, total: 1, inProgress: false, updatedAt: second.updatedAt))
        XCTAssertNil(progress["session-missing"])
    }

    func testLoadTodoProgressBySessionReflectsLaterUpserts() throws {
        let store = makeStore()
        store.upsertTodoSnapshot(sessionId: "session", items: [
            todo(1, "a", .pending),
            todo(2, "b", .pending)
        ])
        store.upsertTodoSnapshot(sessionId: "session", items: [
            todo(1, "a", .completed),
            todo(2, "b", .completed)
        ])

        let updatedAt = try XCTUnwrap(store.fetchTodoSnapshot(sessionId: "session")?.updatedAt)
        XCTAssertEqual(
            store.loadTodoProgressBySession()["session"],
            ChatTodoProgress(done: 2, total: 2, inProgress: false, updatedAt: updatedAt)
        )
    }

    func testFileEditCountsBySessionMatchesPerSessionCounts() async {
        let store = makeStore()
        store.appendFileEdit(sessionId: "session-a", path: "/tmp/one.swift", hunks: [hunk()], containsWrite: true)
        store.appendFileEdit(sessionId: "session-a", path: "/tmp/two.swift", hunks: [hunk()], containsWrite: false)
        store.appendFileEdit(sessionId: "session-b", path: "/tmp/three.swift", hunks: [hunk()], containsWrite: false)

        let snapshot = await ThreadStoreReader(container: store.container).loadMobileSessionData()
        let counts = snapshot.fileEditCounts

        XCTAssertEqual(counts, ["session-a": 2, "session-b": 1])
        XCTAssertEqual(counts["session-a"], store.fileEditCount(sessionId: "session-a"))
    }

    func testLoadTodoListsBySessionPreservesEmptyListsAndTimestamps() async throws {
        let store = makeStore()
        let items = [todo(1, "done", .completed), todo(2, "working", .inProgress)]
        store.upsertTodoSnapshot(sessionId: "session-a", items: items)
        store.upsertTodoSnapshot(sessionId: "session-empty", items: [])

        let snapshot = await ThreadStoreReader(container: store.container).loadMobileSessionData()
        let todos = snapshot.todos
        let populated = try XCTUnwrap(store.fetchTodoSnapshot(sessionId: "session-a"))
        let empty = try XCTUnwrap(store.fetchTodoSnapshot(sessionId: "session-empty"))

        XCTAssertEqual(todos["session-a"], TodoListSnapshot(items: items, updatedAt: populated.updatedAt))
        XCTAssertEqual(todos["session-empty"], TodoListSnapshot(items: [], updatedAt: empty.updatedAt))
        XCTAssertNil(todos["session-missing"])
    }
}
