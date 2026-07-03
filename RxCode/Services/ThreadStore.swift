import Foundation
import SwiftData
import RxCodeCore
import os

/// MainActor-scoped wrapper around the SwiftData store for `ChatThread`.
/// AppState is the only caller; all reads/writes happen on the main actor.
@MainActor
final class ThreadStore {
    let logger = Logger(subsystem: "com.claudework", category: "ThreadStore")
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The full SwiftData schema for the thread store, shared by the file-backed
    /// (`make`) and in-memory (`inMemory`, used by tests) factories.
    static var schema: Schema {
        Schema([
            ChatThread.self,
            TodoSnapshot.self,
            ThreadFileEdit.self,
            QueuedMessageRecord.self,
            PlanDecisionRecord.self,
            ThreadSummaryRecord.self,
            BranchBriefingRecord.self,
            ThreadEmbeddingChunk.self,
            MemoryRecord.self,
            HookStatusRecord.self,
            HookCardRecord.self,
            CustomMenuItemRecord.self
        ])
    }

    /// In-memory store over the full schema, for tests.
    static func inMemory() -> ThreadStore {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ThreadStore(context: ModelContext(container))
    }

    /// Convenience initializer creating its own `ModelContainer` rooted at the
    /// app's Application Support directory.
    static func make(baseURL: URL = AppSupport.bundleScopedURL) -> ThreadStore {
        let schema = Self.schema
        let url = Self.storeURL(baseURL: baseURL)
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let store = ThreadStore(context: ModelContext(container))
            // Sweep hook cards left mid-run by a previous launch so they don't
            // rebuild as a perpetual spinner.
            store.finalizeInterruptedHooks()
            store.finalizeInterruptedHookCards()
            return store
        } catch {
            // Fall back to an in-memory container so the app still launches.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: schema, configurations: [fallback])
            let store = ThreadStore(context: ModelContext(container))
            store.logger.error("Falling back to in-memory ChatThread store: \(error.localizedDescription)")
            return store
        }
    }

    private static func storeURL(baseURL: URL) -> URL {
        let fm = FileManager.default
        let dir = baseURL
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("threads.store")
    }

    // MARK: - Reads

    func loadAllSummaries() -> [ChatSession.Summary] {
        let descriptor = FetchDescriptor<ChatThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do {
            let rows = try context.fetch(descriptor)
            return rows.map { $0.toSummary() }
        } catch {
            logger.error("Fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    func fetch(id: String) -> ChatThread? {
        var descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func cliSessionId(forLocalId id: String) -> String? {
        fetch(id: id)?.cliSessionId
    }

    /// Per-provider native session/resume ids recorded for a thread, keyed by
    /// `AgentProvider.rawValue`. Empty when the thread has never recorded one.
    func providerSessionIds(forLocalId id: String) -> [String: String] {
        fetch(id: id)?.providerSessionIds ?? [:]
    }

    /// Record a provider's native session id on the thread row, merging into the
    /// existing per-provider map. Called when a backend reports its native
    /// session id so a later provider switch can resume the right session.
    func setProviderSessionId(localId: String, providerRaw: String, nativeId: String) {
        guard let row = fetch(id: localId) else { return }
        var map = row.providerSessionIds
        guard map[providerRaw] != nativeId else { return }
        map[providerRaw] = nativeId
        row.providerSessionIds = map
        save()
    }

    func fetchThreadSummary(sessionId: String) -> ThreadSummaryRecord? {
        var descriptor = FetchDescriptor<ThreadSummaryRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func threadSummaryItem(sessionId: String) -> ThreadSummaryItem? {
        fetchThreadSummary(sessionId: sessionId)?.toItem()
    }

    func threadSummaryItems(projectId: UUID, branch: String) -> [ThreadSummaryItem] {
        let descriptor = FetchDescriptor<ThreadSummaryRecord>(
            predicate: #Predicate { $0.projectId == projectId && $0.branch == branch },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toItem() }
    }

    func allThreadSummaryItems() -> [ThreadSummaryItem] {
        let descriptor = FetchDescriptor<ThreadSummaryRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toItem() }
    }

    func branchBriefingItem(projectId: UUID, branch: String) -> BranchBriefingItem? {
        fetchBranchBriefing(projectId: projectId, branch: branch)?.toItem()
    }

    func allBranchBriefingItems() -> [BranchBriefingItem] {
        let descriptor = FetchDescriptor<BranchBriefingRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toItem() }
    }

    @discardableResult
    func deleteBriefingMetadata(excludingProjectIds knownProjectIds: Set<UUID>) -> (threadSummaries: Int, branchBriefings: Int) {
        let summaryRows = (try? context.fetch(FetchDescriptor<ThreadSummaryRecord>())) ?? []
        let orphanedSummaries = summaryRows.filter { !knownProjectIds.contains($0.projectId) }

        let briefingRows = (try? context.fetch(FetchDescriptor<BranchBriefingRecord>())) ?? []
        let orphanedBriefings = briefingRows.filter { !knownProjectIds.contains($0.projectId) }

        guard !orphanedSummaries.isEmpty || !orphanedBriefings.isEmpty else {
            return (0, 0)
        }

        for row in orphanedSummaries { context.delete(row) }
        for row in orphanedBriefings { context.delete(row) }
        save()

        return (orphanedSummaries.count, orphanedBriefings.count)
    }

    /// Remove every thread — and its full per-thread footprint (todo snapshots,
    /// file edits, queues, plan decisions, hook status, summaries, embedding
    /// chunks) — whose project is no longer known. Mirrors
    /// `deleteBriefingMetadata` but covers the data that drives history and
    /// global search. Used at launch to purge orphans left behind by projects
    /// that were deleted before the cascade in `deleteProject` existed (or any
    /// leak), so they never resurface in the sidebar or as "Unknown project"
    /// search results. Returns the number of thread rows removed.
    func pruneOrphanThreads(excludingProjectIds knownProjectIds: Set<UUID>) -> Int {
        let threadRows = (try? context.fetch(FetchDescriptor<ChatThread>())) ?? []
        let orphans = threadRows.filter { !knownProjectIds.contains($0.projectId) }
        let orphanIds = orphans.map(\.id)

        // Also sweep embedding chunks whose owning thread row is already gone —
        // these are what feed the search source directly.
        let chunkRows = (try? context.fetch(FetchDescriptor<ThreadEmbeddingChunk>())) ?? []
        let orphanChunks = chunkRows.filter { !knownProjectIds.contains($0.projectId) }

        guard !orphans.isEmpty || !orphanChunks.isEmpty else { return 0 }

        for row in orphans { context.delete(row) }
        for id in orphanIds {
            deleteTodoSnapshotRow(sessionId: id)
            deleteFileEditRows(sessionId: id)
            deleteQueueRows(sessionKey: id)
            deletePlanDecisionRows(sessionId: id)
            deleteHookStatusRow(sessionId: id)
            deleteHookCardRows(sessionId: id)
            deleteThreadSummaryRow(sessionId: id)
            deleteEmbeddingChunkRows(threadId: id)
        }
        for row in orphanChunks { context.delete(row) }
        save()

        return orphans.count
    }

    // MARK: - Writes

    /// Insert or update a thread row from a summary.
    func upsert(_ summary: ChatSession.Summary, cliSessionId: String? = nil) {
        if let existing = fetch(id: summary.id) {
            existing.apply(summary)
            if let cliSessionId { existing.cliSessionId = cliSessionId }
        } else {
            context.insert(ChatThread.from(summary, cliSessionId: cliSessionId))
        }
        save()
    }

    func upsertThreadSummary(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date = .now
    ) {
        if let existing = fetchThreadSummary(sessionId: sessionId) {
            existing.apply(projectId: projectId, branch: branch, title: title, summary: summary, updatedAt: updatedAt)
        } else {
            context.insert(ThreadSummaryRecord(
                sessionId: sessionId,
                projectId: projectId,
                branch: branch,
                title: title,
                summary: summary,
                updatedAt: updatedAt
            ))
        }
        save()
    }

    func upsertThreadSummaryTitle(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        updatedAt: Date = .now
    ) {
        if let existing = fetchThreadSummary(sessionId: sessionId) {
            existing.applyTitle(
                projectId: projectId,
                branch: branch,
                title: title,
                updatedAt: updatedAt
            )
        } else {
            let seed = ThreadSummaryItem.titleSeed(
                sessionId: sessionId,
                projectId: projectId,
                branch: branch,
                title: title,
                updatedAt: updatedAt
            )
            context.insert(ThreadSummaryRecord(
                sessionId: seed.sessionId,
                projectId: seed.projectId,
                branch: seed.branch,
                title: seed.title,
                summary: seed.summary,
                updatedAt: seed.updatedAt
            ))
        }
        save()
    }

    func upsertBranchBriefing(projectId: UUID, branch: String, briefing: String, updatedAt: Date = .now) {
        if let existing = fetchBranchBriefing(projectId: projectId, branch: branch) {
            existing.apply(briefing: briefing, updatedAt: updatedAt)
        } else {
            context.insert(BranchBriefingRecord(
                projectId: projectId,
                branch: branch,
                briefing: briefing,
                updatedAt: updatedAt,
                lastSeenAt: updatedAt
            ))
        }
        save()
    }

    /// Mark a branch's briefing as recently observed, resetting the TTL used by
    /// `purgeStaleBranchBriefings`. No-op if no record exists.
    func touchBranchBriefing(projectId: UUID, branch: String, at date: Date = .now) {
        guard let row = fetchBranchBriefing(projectId: projectId, branch: branch) else { return }
        row.touch(at: date)
        save()
    }

    /// Delete branch briefings whose `lastSeenAt` is older than `cutoff` — i.e.
    /// branches that haven't been observed for the retention window and have
    /// presumably been deleted both locally and remotely. Returns the deleted
    /// record ids.
    @discardableResult
    func purgeStaleBranchBriefings(olderThan cutoff: Date) -> [String] {
        let descriptor = FetchDescriptor<BranchBriefingRecord>(
            predicate: #Predicate { $0.lastSeenAt < cutoff }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id)
        for row in rows { context.delete(row) }
        save()
        return ids
    }

    /// Persist the latest code-review verdict on the thread row so the sidebar
    /// review dot survives a reload. `sessionId` may be the thread's local id or
    /// its resolved CLI session id — match either. No-op if no row is found.
    func setReviewPassed(sessionId: String, passed: Bool) {
        let row = fetch(id: sessionId) ?? fetchByCliSessionId(sessionId)
        guard let row else { return }
        guard row.reviewPassed != passed else { return }
        row.reviewPassed = passed
        save()
    }

    /// Rehydrate the in-memory `reviewPassedBySession` map at launch. Keyed by
    /// both the thread's local id and its CLI session id so either lookup hits.
    func loadReviewVerdicts() -> [String: Bool] {
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

    private func fetchByCliSessionId(_ cliSessionId: String) -> ChatThread? {
        var descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.cliSessionId == cliSessionId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Set `cliSessionId` on the thread row (used when the CLI assigns a session id mid-stream).
    func setCliSessionId(localId: String, cliSessionId: String) {
        guard let row = fetch(id: localId) else { return }
        row.cliSessionId = cliSessionId
        save()
    }

    /// Rename a thread row's id (used when AppState swaps placeholder → CLI sid in `allSessionSummaries`).
    /// Preserves all metadata.
    func renameId(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetch(id: oldId) else { return }
        // If a row already exists at newId, drop oldId and prefer the newId row.
        if let existingAtNew = fetch(id: newId) {
            // Keep the more useful title/metadata from oldId if newId is still default.
            if existingAtNew.title == ChatSession.defaultTitle, row.title != ChatSession.defaultTitle {
                existingAtNew.title = row.title
            }
            if existingAtNew.cliSessionId == nil { existingAtNew.cliSessionId = newId }
            if existingAtNew.providerSessionIdsJSON == nil {
                existingAtNew.providerSessionIdsJSON = row.providerSessionIdsJSON
            }
            context.delete(row)
        } else {
            row.id = newId
            if row.cliSessionId == nil { row.cliSessionId = newId }
        }
        renameTodoSnapshot(from: oldId, to: newId)
        renameFileEdits(from: oldId, to: newId)
        renameQueueKey(from: oldId, to: newId)
        renamePlanDecisions(from: oldId, to: newId)
        renameHookStatus(from: oldId, to: newId)
        renameHookCards(from: oldId, to: newId)
        renameThreadSummary(from: oldId, to: newId)
        save()
    }

    /// Mark a thread row as archived (or restore it). Returns the updated summary
    /// on success so callers can keep `allSessionSummaries` in sync.
    @discardableResult
    func setArchived(id: String, archived: Bool, at date: Date = .now) -> ChatSession.Summary? {
        guard let row = fetch(id: id) else { return nil }
        row.isArchived = archived
        row.archivedAt = archived ? date : nil
        save()
        return row.toSummary()
    }

    /// Return the ids of archived, non-pinned threads whose `archivedAt` is older
    /// than `cutoff`. Caller is responsible for routing each id through the full
    /// delete path (persistence + search service + SwiftData) — see `AppState`.
    func staleArchivedIds(olderThan cutoff: Date) -> [String] {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { row in
                row.isArchived == true && row.isPinned == false && row.archivedAt != nil && row.archivedAt! < cutoff
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map(\.id)
    }

    /// Archive all non-pinned, non-archived threads whose `updatedAt` is older than
    /// `cutoff`. Returns the ids that were archived.
    func archiveStale(olderThan cutoff: Date, now: Date = .now) -> [String] {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { row in
                row.isArchived == false && row.isPinned == false && row.updatedAt < cutoff
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return [] }
        for row in rows {
            row.isArchived = true
            row.archivedAt = now
        }
        save()
        return rows.map(\.id)
    }

    func delete(id: String) {
        guard let row = fetch(id: id) else { return }
        context.delete(row)
        deleteTodoSnapshotRow(sessionId: id)
        deleteFileEditRows(sessionId: id)
        deleteQueueRows(sessionKey: id)
        deletePlanDecisionRows(sessionId: id)
        deleteHookStatusRow(sessionId: id)
        deleteHookCardRows(sessionId: id)
        deleteThreadSummaryRow(sessionId: id)
        deleteEmbeddingChunkRows(threadId: id)
        save()
    }

    func deleteAll(projectId: UUID?) {
        let descriptor: FetchDescriptor<ChatThread>
        if let projectId {
            descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.projectId == projectId })
        } else {
            descriptor = FetchDescriptor<ChatThread>()
        }
        do {
            let rows = try context.fetch(descriptor)
            let ids = rows.map(\.id)
            for row in rows { context.delete(row) }
            for id in ids {
                deleteTodoSnapshotRow(sessionId: id)
                deleteFileEditRows(sessionId: id)
                deleteQueueRows(sessionKey: id)
                deletePlanDecisionRows(sessionId: id)
                deleteHookStatusRow(sessionId: id)
                deleteHookCardRows(sessionId: id)
                deleteThreadSummaryRow(sessionId: id)
                deleteEmbeddingChunkRows(threadId: id)
            }
            if projectId == nil {
                let allTodos = (try? context.fetch(FetchDescriptor<TodoSnapshot>())) ?? []
                for row in allTodos { context.delete(row) }
                let allEdits = (try? context.fetch(FetchDescriptor<ThreadFileEdit>())) ?? []
                for row in allEdits { context.delete(row) }
                let allQueues = (try? context.fetch(FetchDescriptor<QueuedMessageRecord>())) ?? []
                for row in allQueues { context.delete(row) }
                let allPlans = (try? context.fetch(FetchDescriptor<PlanDecisionRecord>())) ?? []
                for row in allPlans { context.delete(row) }
                let allHookStatuses = (try? context.fetch(FetchDescriptor<HookStatusRecord>())) ?? []
                for row in allHookStatuses { context.delete(row) }
                let allHookCards = (try? context.fetch(FetchDescriptor<HookCardRecord>())) ?? []
                for row in allHookCards { context.delete(row) }
                let allSummaries = (try? context.fetch(FetchDescriptor<ThreadSummaryRecord>())) ?? []
                for row in allSummaries { context.delete(row) }
                let allBriefings = (try? context.fetch(FetchDescriptor<BranchBriefingRecord>())) ?? []
                for row in allBriefings { context.delete(row) }
                let allChunks = (try? context.fetch(FetchDescriptor<ThreadEmbeddingChunk>())) ?? []
                for row in allChunks { context.delete(row) }
            } else if let projectId {
                let briefingDescriptor = FetchDescriptor<BranchBriefingRecord>(
                    predicate: #Predicate { $0.projectId == projectId }
                )
                let briefings = (try? context.fetch(briefingDescriptor)) ?? []
                for row in briefings { context.delete(row) }
                let chunkDescriptor = FetchDescriptor<ThreadEmbeddingChunk>(
                    predicate: #Predicate { $0.projectId == projectId }
                )
                let chunks = (try? context.fetch(chunkDescriptor)) ?? []
                for row in chunks { context.delete(row) }
            }
            save()
        } catch {
            logger.error("deleteAll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Thread Summaries

    private func renameThreadSummary(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetchThreadSummary(sessionId: oldId) else { return }
        if fetchThreadSummary(sessionId: newId) != nil {
            context.delete(row)
        } else {
            row.sessionId = newId
        }
    }

    private func deleteThreadSummaryRow(sessionId: String) {
        guard let row = fetchThreadSummary(sessionId: sessionId) else { return }
        context.delete(row)
    }

    private func fetchBranchBriefing(projectId: UUID, branch: String) -> BranchBriefingRecord? {
        let id = BranchBriefingRecord.makeId(projectId: projectId, branch: branch)
        var descriptor = FetchDescriptor<BranchBriefingRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Todo Snapshots

    func fetchTodoSnapshot(sessionId: String) -> TodoSnapshot? {
        var descriptor = FetchDescriptor<TodoSnapshot>(predicate: #Predicate { $0.sessionId == sessionId })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func upsertTodoSnapshot(sessionId: String, items: [TodoItem]) {
        if let existing = fetchTodoSnapshot(sessionId: sessionId) {
            existing.apply(items: items)
        } else {
            context.insert(TodoSnapshot(sessionId: sessionId, items: items))
        }
        save()
    }

    func renameTodoSnapshot(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetchTodoSnapshot(sessionId: oldId) else { return }
        if let existing = fetchTodoSnapshot(sessionId: newId) {
            // Prefer the row tied to the new sid; drop the placeholder row.
            context.delete(row)
            _ = existing
        } else {
            row.sessionId = newId
        }
        save()
    }

    func deleteTodoSnapshot(sessionId: String) {
        deleteTodoSnapshotRow(sessionId: sessionId)
        save()
    }

    private func deleteTodoSnapshotRow(sessionId: String) {
        guard let row = fetchTodoSnapshot(sessionId: sessionId) else { return }
        context.delete(row)
    }

    // MARK: - Plan Decisions

    private func fetchPlanDecision(sessionId: String, toolCallId: String) -> PlanDecisionRecord? {
        var descriptor = FetchDescriptor<PlanDecisionRecord>(
            predicate: #Predicate { $0.sessionId == sessionId && $0.toolCallId == toolCallId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func loadPlanDecisions(sessionId: String) -> [String: String] {
        let descriptor = FetchDescriptor<PlanDecisionRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var map: [String: String] = [:]
        for row in rows { map[row.toolCallId] = row.summary }
        return map
    }

    func setPlanDecision(sessionId: String, toolCallId: String, summary: String) {
        if let existing = fetchPlanDecision(sessionId: sessionId, toolCallId: toolCallId) {
            existing.summary = summary
            existing.updatedAt = .now
        } else {
            context.insert(PlanDecisionRecord(
                sessionId: sessionId,
                toolCallId: toolCallId,
                summary: summary
            ))
        }
        save()
    }

    private func planDecisions(sessionId: String) -> [PlanDecisionRecord] {
        let descriptor = FetchDescriptor<PlanDecisionRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func renamePlanDecisions(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        for row in planDecisions(sessionId: oldId) {
            if fetchPlanDecision(sessionId: newId, toolCallId: row.toolCallId) != nil {
                context.delete(row)
            } else {
                row.sessionId = newId
            }
        }
    }

    private func deletePlanDecisionRows(sessionId: String) {
        for row in planDecisions(sessionId: sessionId) { context.delete(row) }
    }

    // MARK: - Hook Cards

    /// All persisted hook cards for a session, oldest first, so a reload rebuilds
    /// them in the order they were originally inserted.
    func loadHookCards(sessionId: String) -> [HookCardRecord] {
        let descriptor = FetchDescriptor<HookCardRecord>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchHookCard(toolId: String) -> HookCardRecord? {
        var descriptor = FetchDescriptor<HookCardRecord>(
            predicate: #Predicate { $0.toolId == toolId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Insert (or update) a hook card row keyed by its tool-call id. Called at
    /// insert time (in-progress) and again on completion so the card survives a
    /// reload at any point in its lifecycle.
    func upsertHookCard(
        sessionId: String,
        toolId: String,
        toolName: String,
        input: [String: JSONValue],
        result: String?,
        isError: Bool,
        isComplete: Bool
    ) {
        let data = (try? JSONEncoder().encode(input)) ?? Data()
        if let existing = fetchHookCard(toolId: toolId) {
            existing.sessionId = sessionId
            existing.toolName = toolName
            existing.inputData = data
            existing.result = result
            existing.isError = isError
            existing.isComplete = isComplete
            existing.updatedAt = .now
        } else {
            context.insert(HookCardRecord(
                toolId: toolId,
                sessionId: sessionId,
                toolName: toolName,
                inputData: data,
                result: result,
                isError: isError,
                isComplete: isComplete
            ))
        }
        save()
    }

    /// Update a previously-inserted card's result/state on completion,
    /// preserving its stored `toolName`/`input`. Returns `false` (no-op) if the
    /// row isn't found, so callers can fall back to an insert.
    @discardableResult
    func completeHookCard(toolId: String, result: String, isError: Bool, isComplete: Bool = true) -> Bool {
        guard let row = fetchHookCard(toolId: toolId) else { return false }
        row.result = result
        row.isError = isError
        row.isComplete = isComplete
        row.updatedAt = .now
        save()
        return true
    }

    /// Finalize any hook card rows left "in progress" by a previous launch (the
    /// app closed while a long-running hook like code review was still running).
    /// Without this they would rebuild as a spinner that never resolves.
    func finalizeInterruptedHookCards() {
        let descriptor = FetchDescriptor<HookCardRecord>(
            predicate: #Predicate { $0.isComplete == false }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows {
            row.isComplete = true
            row.isError = true
            if (row.result ?? "").isEmpty {
                row.result = "Interrupted — the app closed while this hook was running."
            }
            row.updatedAt = .now
        }
        save()
    }

    private func renameHookCards(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        for row in loadHookCards(sessionId: oldId) { row.sessionId = newId }
    }

    private func deleteHookCardRows(sessionId: String) {
        for row in loadHookCards(sessionId: sessionId) { context.delete(row) }
    }

    // MARK: - Hook Status (legacy)

    private func fetchHookStatus(sessionId: String) -> HookStatusRecord? {
        var descriptor = FetchDescriptor<HookStatusRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Finalize any hook rows left "in progress" by a previous launch (the app
    /// closed while a long-running hook like code review was still streaming).
    /// Without this they would rebuild as a spinner that never resolves.
    func finalizeInterruptedHooks() {
        let descriptor = FetchDescriptor<HookStatusRecord>(
            predicate: #Predicate { $0.isComplete == false }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows {
            row.isComplete = true
            row.isError = true
            if row.output.isEmpty {
                row.output = "Interrupted — the app closed while this hook was running."
            }
            row.updatedAt = .now
        }
        save()
    }

    /// Stamp linkage metadata (parent thread / label / skip-hooks) onto a thread
    /// row. Used right after a linked `[Code Review]` thread's real id resolves.
    func setThreadLinkage(
        sessionId: String,
        parentThreadId: String?,
        threadLabel: String?,
        skipHooks: Bool
    ) {
        guard let thread = fetch(id: sessionId) else { return }
        thread.parentThreadId = parentThreadId
        thread.threadLabel = threadLabel
        thread.skipHooks = skipHooks
        save()
    }

    private func renameHookStatus(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetchHookStatus(sessionId: oldId) else { return }
        if fetchHookStatus(sessionId: newId) != nil {
            context.delete(row)
        } else {
            row.sessionId = newId
        }
    }

    private func deleteHookStatusRow(sessionId: String) {
        guard let row = fetchHookStatus(sessionId: sessionId) else { return }
        context.delete(row)
    }

    // MARK: - Thread File Edits

    func fetchFileEdits(sessionId: String) -> [ThreadFileEdit] {
        let descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.firstEditedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Number of distinct files this session recorded edits to. There is one row
    /// per `(sessionId, path)`, so a row count equals the distinct-file count —
    /// a cheap query (no content loaded) used to gate the "Commit Files" action.
    func fileEditCount(sessionId: String) -> Int {
        let descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func fetchFileEdit(sessionId: String, path: String) -> ThreadFileEdit? {
        var descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId && $0.path == path }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Append edit hunks to the file's row for this session, creating the row if it
    /// does not yet exist. Hunks are aggregated across turns; `containsWrite` becomes
    /// sticky once any Write contributes.
    ///
    /// `originalContent` is the file's contents captured at the very first edit
    /// to this path within this session. It's stored only on row creation —
    /// subsequent calls preserve the original snapshot rather than overwriting
    /// it, so the diff view always compares against the true thread-start state.
    ///
    /// `modifiedContent` is the file's contents re-read from disk immediately
    /// after the tool_result. Unlike `originalContent` it is **always
    /// overwritten** on subsequent edits so the "after" side reflects this
    /// thread's most recent committed state.
    func appendFileEdit(
        sessionId: String,
        path: String,
        hunks: [PreviewFile.EditHunk],
        containsWrite: Bool,
        originalContent: String? = nil,
        modifiedContent: String? = nil
    ) {
        guard !hunks.isEmpty else { return }
        let name = (path as NSString).lastPathComponent
        if let existing = fetchFileEdit(sessionId: sessionId, path: path) {
            existing.append(hunks: hunks, containsWrite: containsWrite)
            existing.name = name
            if existing.originalContent == nil, let originalContent {
                existing.originalContent = originalContent
            }
            existing.modifiedContent = modifiedContent
        } else {
            context.insert(ThreadFileEdit(
                sessionId: sessionId,
                path: path,
                name: name,
                hunks: hunks,
                containsWrite: containsWrite,
                originalContent: originalContent,
                modifiedContent: modifiedContent
            ))
        }
        save()
    }

    func renameFileEdits(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        let rows = fetchFileEdits(sessionId: oldId)
        for row in rows {
            if let existing = fetchFileEdit(sessionId: newId, path: row.path) {
                existing.append(hunks: row.hunks, containsWrite: row.containsWrite)
                context.delete(row)
            } else {
                row.sessionId = newId
            }
        }
    }

    func deleteFileEdits(sessionId: String) {
        deleteFileEditRows(sessionId: sessionId)
        save()
    }

    private func deleteFileEditRows(sessionId: String) {
        for row in fetchFileEdits(sessionId: sessionId) { context.delete(row) }
    }

    // MARK: - Queued Messages

    func loadQueue(sessionKey: String) -> [QueuedMessage] {
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.sessionKey == sessionKey },
            sortBy: [SortDescriptor(\.order, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map { $0.toQueuedMessage() }
    }

    func loadAllQueues() -> [String: [QueuedMessage]] {
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

    private func nextQueueOrder(sessionKey: String) -> Int {
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.sessionKey == sessionKey },
            sortBy: [SortDescriptor(\.order, order: .reverse)]
        )
        var d = descriptor
        d.fetchLimit = 1
        let max = (try? context.fetch(d))?.first?.order ?? -1
        return max + 1
    }

    func appendQueued(sessionKey: String, message: QueuedMessage) {
        let record = QueuedMessageRecord(
            id: message.id,
            sessionKey: sessionKey,
            order: nextQueueOrder(sessionKey: sessionKey),
            text: message.text,
            attachmentsData: QueuedMessageRecord.encodeAttachments(message.attachments)
        )
        context.insert(record)
        save()
    }

    func removeQueued(id: UUID) {
        var descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let row = (try? context.fetch(descriptor))?.first else { return }
        context.delete(row)
        save()
    }

    func clearQueue(sessionKey: String) {
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.sessionKey == sessionKey }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
        save()
    }

    func renameQueueKey(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.sessionKey == oldKey }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { row.sessionKey = newKey }
        save()
    }

    private func deleteQueueRows(sessionKey: String) {
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.sessionKey == sessionKey }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
    }

    func save() {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { logger.error("Save failed: \(error.localizedDescription)") }
    }
}
