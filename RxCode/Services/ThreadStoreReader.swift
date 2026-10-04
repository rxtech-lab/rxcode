import Foundation
import RxCodeCore
import SwiftData
import os

// MARK: - ThreadStartupSnapshot

/// Everything the sidebar needs from the thread store at launch, as plain
/// values that can cross back to the main actor.
nonisolated struct ThreadStartupSnapshot: Sendable {
    var summaries: [ChatSession.Summary] = []
    var reviewVerdicts: [String: Bool] = [:]
    var sessionIdsWithFileEdits: Set<String> = []
    var todoProgress: [String: ChatTodoProgress] = [:]
    var queues: [String: [QueuedMessage]] = [:]
}

// MARK: - EmbeddingChunkSnapshot

/// A persisted embedding chunk as plain values, so the search index can be
/// hydrated without model objects (and their blob columns) crossing the main
/// actor.
nonisolated struct EmbeddingChunkSnapshot: Sendable {
    let threadId: String
    let projectId: UUID
    let chunkIndex: Int
    let text: String
    let vector: [Float]
}

// MARK: - ThreadStoreReader

/// Background reader over the thread store.
///
/// `ThreadStore` is main-actor bound, which is right for the writes the UI
/// drives. Launch, though, needs five whole-table reads whose results are pure
/// values — on a long-lived install that is a thousand threads and several
/// thousand file-edit rows of SQLite work, and on the main thread it holds up
/// the first frame.
///
/// Deliberately *not* a `@ModelActor`: that macro builds the `ModelContext` and
/// its serial executor inside the generated initializer, so a reader
/// constructed from `AppState.init` (which is `@MainActor`) can end up running
/// its fetches on the main executor — exactly what this type exists to avoid.
/// Instead each read runs in a detached task that makes, uses and discards its
/// own context there, so the work is off the main thread no matter where the
/// reader was created, and only plain values cross back.
nonisolated struct ThreadStoreReader: Sendable {
    private static let logger = Logger(subsystem: "com.claudework", category: "ThreadStoreReader")

    /// `ModelContainer` is `Sendable`; the per-read `ModelContext` never leaves
    /// the thread that created it.
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// One background pass for every index the sidebar reads at launch.
    func loadStartupSnapshot() async -> ThreadStartupSnapshot {
        await read { context in
            ThreadStartupSnapshot(
                summaries: Self.summaries(in: context),
                reviewVerdicts: Self.reviewVerdicts(in: context),
                sessionIdsWithFileEdits: Self.sessionIdsWithFileEdits(in: context),
                todoProgress: Self.todoProgress(in: context),
                queues: Self.queues(in: context)
            )
        }
    }

    /// Thread summaries alone, for callers that only need the sidebar list
    /// refreshed (e.g. after a launch-time prune removed orphan rows).
    func loadSummaries() async -> [ChatSession.Summary] {
        await read { Self.summaries(in: $0) }
    }

    /// Every persisted embedding chunk, as values. This is the largest read in
    /// the app — one vector blob per chunk — so it belongs off the main thread.
    func loadEmbeddingChunkSnapshots() async -> [EmbeddingChunkSnapshot] {
        await read { Self.embeddingChunks(in: $0) }
    }

    /// Runs `body` on the cooperative pool against a context of this reader's
    /// own, and hands back the (`Sendable`) result.
    ///
    /// Every read above goes through here, so a test that asserts this lands
    /// off the main thread covers all of them.
    func read<T: Sendable>(_ body: @escaping @Sendable (ModelContext) -> T) async -> T {
        let container = container
        return await Task.detached(priority: .userInitiated) {
            assert(!Thread.isMainThread, "ThreadStoreReader reads must not run on the main thread")
            return body(ModelContext(container))
        }.value
    }

    // MARK: - Fetches

    private static func summaries(in context: ModelContext) -> [ChatSession.Summary] {
        let descriptor = FetchDescriptor<ChatThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor).map { $0.toSummary() }
        } catch {
            logger.error("Summary fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Mirrors `ThreadStore.loadReviewVerdicts()`: keyed by both the thread's
    /// local id and its CLI session id so either lookup hits.
    private static func reviewVerdicts(in context: ModelContext) -> [String: Bool] {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.reviewPassed != nil }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var map: [String: Bool] = [:]
        for row in rows {
            guard let passed = row.reviewPassed else { continue }
            map[row.id] = passed
            if let cli = row.cliSessionId { map[cli] = passed }
        }
        return map
    }

    /// Only `sessionId` is fetched — the rows also carry original/updated file
    /// contents, which are by far the largest thing in the store.
    private static func sessionIdsWithFileEdits(in context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<ThreadFileEdit>()
        descriptor.propertiesToFetch = [\.sessionId]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.sessionId))
    }

    /// Counts only, never `itemsData` — the sidebar's progress ring needs
    /// numbers, not the encoded item list.
    private static func todoProgress(in context: ModelContext) -> [String: ChatTodoProgress] {
        var descriptor = FetchDescriptor<TodoSnapshot>()
        descriptor.propertiesToFetch = [\.sessionId, \.done, \.total, \.inProgress]
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.reduce(into: [:]) { result, row in
            result[row.sessionId] = ChatTodoProgress(
                done: row.done,
                total: row.total,
                inProgress: row.inProgress > 0
            )
        }
    }

    private static func queues(in context: ModelContext) -> [String: [QueuedMessage]] {
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            sortBy: [SortDescriptor(\.order, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var grouped: [String: [QueuedMessage]] = [:]
        for row in rows {
            grouped[row.sessionKey, default: []].append(row.toQueuedMessage())
        }
        return grouped
    }

    private static func embeddingChunks(in context: ModelContext) -> [EmbeddingChunkSnapshot] {
        let descriptor = FetchDescriptor<ThreadEmbeddingChunk>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map {
            EmbeddingChunkSnapshot(
                threadId: $0.threadId,
                projectId: $0.projectId,
                chunkIndex: $0.chunkIndex,
                text: $0.text,
                vector: $0.floatVector()
            )
        }
    }
}
