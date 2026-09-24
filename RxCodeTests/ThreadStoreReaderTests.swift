import XCTest
import SwiftData
import RxCodeCore
@testable import RxCode

/// Launch reads the sidebar's indexes through `ThreadStoreReader`, which opens
/// its own `ModelContext` off the main thread. These pin the background answers
/// to the main-actor `ThreadStore` ones, so moving the work never silently
/// changes what the sidebar shows — and pin the "off the main thread" part
/// itself, which is the whole point of the type.
@MainActor
final class ThreadStoreReaderTests: XCTestCase {

    // `ThreadStore` is `@MainActor`, so its synthesized deinit hops executors via
    // the Swift concurrency runtime — which double-frees when a local store
    // deallocates at a test's return. Retain every store for the test process so
    // that deinit never runs mid-run (see `ThreadStoreSidebarIndexTests`).
    private static var retainedStores: [ThreadStore] = []
    private func makeStore() -> ThreadStore {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        return store
    }

    private func summary(_ id: String, projectId: UUID, title: String) -> ChatSession.Summary {
        ChatSession.Summary(
            id: id,
            projectId: projectId,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            isPinned: false
        )
    }

    // MARK: - Off-main execution

    /// The reader is built on the main actor in the app (`AppState.init`), so
    /// build it that way here too: the guarantee has to come from how the reads
    /// run, not from where the reader was created.
    func testFetchesRunOffTheMainThreadEvenThoughTheReaderIsMadeOnTheMainActor() async {
        XCTAssertTrue(Thread.isMainThread, "precondition: the reader is constructed on the main thread")
        let store = makeStore()
        store.upsert(summary("session", projectId: UUID(), title: "Thread"))
        let reader = ThreadStoreReader(container: store.container)

        // `read` is the single entry point every loader on the type goes
        // through, so this covers all of them. Fetch inside it as well, to pin
        // that it is the SwiftData work — not just the hop — that lands here.
        let (wasMainThread, threadCount) = await reader.read { context -> (Bool, Int) in
            let rows = (try? context.fetch(FetchDescriptor<ChatThread>())) ?? []
            return (Thread.isMainThread, rows.count)
        }

        XCTAssertFalse(wasMainThread, "ThreadStoreReader fetches must not run on the main thread")
        XCTAssertEqual(threadCount, 1)
    }

    // MARK: - Parity with ThreadStore

    func testStartupSnapshotMatchesTheMainActorStore() async {
        let store = makeStore()
        let projectId = UUID()
        store.upsert(summary("session-a", projectId: projectId, title: "First"))
        store.upsert(summary("session-b", projectId: projectId, title: "Second"))
        store.setReviewPassed(sessionId: "session-a", passed: true)
        store.appendFileEdit(
            sessionId: "session-b",
            path: "/tmp/one.swift",
            hunks: [PreviewFile.EditHunk(oldString: "before", newString: "after")],
            containsWrite: true
        )
        store.upsertTodoSnapshot(sessionId: "session-a", items: [
            TodoItem(id: 1, content: "done", activeForm: "done", status: .completed),
            TodoItem(id: 2, content: "next", activeForm: "next", status: .inProgress)
        ])
        store.appendQueued(sessionKey: "session-b", message: QueuedMessage(text: "queued", attachments: []))

        let reader = ThreadStoreReader(container: store.container)
        let snapshot = await reader.loadStartupSnapshot()

        XCTAssertEqual(snapshot.summaries.map(\.id), store.loadAllSummaries().map(\.id))
        XCTAssertEqual(snapshot.reviewVerdicts, store.loadReviewVerdicts())
        XCTAssertEqual(snapshot.sessionIdsWithFileEdits, store.sessionIdsWithFileEdits())
        XCTAssertEqual(snapshot.todoProgress, store.loadTodoProgressBySession())
        XCTAssertEqual(
            snapshot.queues.mapValues { $0.map(\.text) },
            store.loadAllQueues().mapValues { $0.map(\.text) }
        )
    }

    /// The sidebar list is the one index the launch path publishes before the
    /// maintenance sweeps run, and reloads afterwards — so ordering (most
    /// recently updated first) has to survive the move to the reader.
    func testSummariesComeBackNewestFirst() async {
        let store = makeStore()
        let projectId = UUID()
        var older = summary("older", projectId: projectId, title: "Older")
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = summary("newer", projectId: projectId, title: "Newer")
        newer.updatedAt = Date(timeIntervalSince1970: 9_000)
        store.upsert(older)
        store.upsert(newer)

        let reader = ThreadStoreReader(container: store.container)

        let ids = await reader.loadSummaries().map(\.id)

        XCTAssertEqual(ids, ["newer", "older"])
    }

    func testStartupSnapshotIsEmptyForAFreshStore() async {
        let reader = ThreadStoreReader(container: makeStore().container)
        let snapshot = await reader.loadStartupSnapshot()

        XCTAssertTrue(snapshot.summaries.isEmpty)
        XCTAssertTrue(snapshot.reviewVerdicts.isEmpty)
        XCTAssertTrue(snapshot.sessionIdsWithFileEdits.isEmpty)
        XCTAssertTrue(snapshot.todoProgress.isEmpty)
        XCTAssertTrue(snapshot.queues.isEmpty)
    }
}
