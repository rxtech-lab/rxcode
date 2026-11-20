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
        XCTAssertEqual(snapshot.fileEditPresence, ThreadStore.fileEditPresence(in: store.context))
        XCTAssertEqual(snapshot.todoProgress, store.loadTodoProgressBySession())
        XCTAssertEqual(
            snapshot.queues.mapValues { $0.map(\.text) },
            ["session-b": store.loadQueue(sessionKey: "session-b").map(\.text)]
        )
    }

    func testDiffPreviewLoadsOnlyTheRequestedThreadsProjectFiles() async {
        let store = makeStore()
        let hunks = [PreviewFile.EditHunk(oldString: "before", newString: "after")]
        store.appendFileEdit(sessionId: "session-a", path: "/tmp/file.swift", hunks: hunks, containsWrite: false)
        store.appendFileEdit(sessionId: "session-a", path: "/tmp/.claude/plans/plan.md", hunks: hunks, containsWrite: true)
        store.appendFileEdit(sessionId: "session-b", path: "/tmp/other.swift", hunks: hunks, containsWrite: false)

        let reader = ThreadStoreReader(container: store.container)
        let edits = await reader.loadThreadDiffPreview(sessionId: "session-a")
        let count = await reader.loadVisibleFileEditCount(sessionId: "session-a")

        XCTAssertEqual(edits.map(\.path), ["/tmp/file.swift"])
        XCTAssertEqual(edits.first?.hunks, hunks)
        XCTAssertEqual(count, edits.count)
    }

    func testCheckoutBranchSurvivesSessionRenameWithoutAnAISummary() async {
        let store = makeStore()
        let projectId = UUID()
        store.upsert(summary("pending", projectId: projectId, title: "New thread"))
        store.upsert(summary("real", projectId: projectId, title: "New thread"))
        store.setCheckoutBranch(sessionId: "pending", branch: "feature")
        store.renameId(from: "pending", to: "real")
        store.upsert(summary("real", projectId: projectId, title: "Updated title"))
        store.upsertThreadSummaryTitle(sessionId: "older", projectId: projectId, branch: "legacy", title: "Older")
        store.upsertThreadSummaryTitle(sessionId: "no-branch", projectId: projectId, branch: "unknown", title: "No branch")

        let reader = ThreadStoreReader(container: store.container)
        let branches = await reader.loadThreadBranches()

        XCTAssertEqual(branches, ["real": ["feature"], "older": ["legacy"]])
        XCTAssertNil(store.threadSummaryItem(sessionId: "real"))
    }

    func testPullRequestMatchingUsesCommittedEditsAndRequiresOneMatchingPR() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.path
        let file = directory.appending(path: "Feature File.swift")
        let before = "let value = 1\n"
        let after = "let value = 2\n"

        func git(_ arguments: [String]) async throws -> String {
            let output = await GitHelper.run(arguments, at: path)
            return try XCTUnwrap(output).trimmingCharacters(in: .newlines)
        }

        _ = try await git(["init", "-b", "main"])
        try before.write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", file.lastPathComponent])
        let author = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        _ = try await git(author + ["commit", "-m", "Base"])
        let base = try await git(["rev-parse", "HEAD"])

        let store = makeStore()
        let project = Project(name: "Repo", path: path, gitHubRepo: "owner/repo")
        let threads = ["before-branch", "same-file-other-edit", "ambiguous-edit"].map {
            summary($0, projectId: project.id, title: $0)
        }
        for thread in threads {
            store.upsert(thread)
            let edited = thread.id == "same-file-other-edit" ? "let value = 3\n" : after
            store.appendFileEdit(
                sessionId: thread.id, path: file.path,
                hunks: [PreviewFile.EditHunk(oldString: before, newString: edited)],
                containsWrite: false, originalContent: before, modifiedContent: edited,
                isAmbiguous: thread.id == "ambiguous-edit"
            )
        }

        try after.write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["checkout", "-b", "feature"])
        _ = try await git(author + ["commit", "-am", "Commit the saved edit"])
        let head = try await git(["rev-parse", "HEAD"])

        func revision(_ number: Int) -> ThreadPullRequestRevision {
            ThreadPullRequestRevision(
                repositoryFullName: "Owner/Repo", number: number, state: "merged", htmlUrl: nil,
                baseSha: base, headSha: head, updatedAt: FlexibleTimestamp(date: .now)
            )
        }
        let reader = ThreadStoreReader(container: store.container)
        let matcher = ThreadPullRequestMatcher()
        let matches = await matcher.match([revision(375)], to: threads, in: [project], reader: reader)
        XCTAssertEqual(Set(matches.keys), ["before-branch"])
        XCTAssertEqual(matches["before-branch"]?.url.absoluteString, "https://github.com/owner/repo/pull/375")
        XCTAssertEqual(matches["before-branch"]?.state, .merged)

        let ambiguous = await matcher.match([revision(375), revision(376)], to: threads, in: [project], reader: reader)
        XCTAssertTrue(ambiguous.isEmpty)
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
        XCTAssertTrue(snapshot.fileEditPresence.isEmpty)
        XCTAssertTrue(snapshot.todoProgress.isEmpty)
        XCTAssertTrue(snapshot.queues.isEmpty)
    }
}
