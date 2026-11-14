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
    /// Kept so background readers can open their own context over the same
    /// store — see `ThreadStoreReader`.
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
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

    /// Keep repository context with globally owned chats before removing a project.
    func retainProjectContext(_ project: Project) {
        let projectId = project.id
        let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.projectId == projectId })
        for row in (try? context.fetch(descriptor)) ?? [] {
            row.retainedProjectName = project.name
            row.retainedProjectPath = project.path
        }
        save()
    }

    func retainedProject(id: UUID) -> Project? {
        var descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate {
            $0.projectId == id && $0.retainedProjectPath != nil
        })
        descriptor.fetchLimit = 1
        guard let row = (try? context.fetch(descriptor))?.first,
              let path = row.retainedProjectPath else { return nil }
        return Project(id: id, name: row.retainedProjectName ?? URL(fileURLWithPath: path).lastPathComponent, path: path)
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

    /// The day briefing for `branch` on the day containing `day`.
    func branchBriefingItem(projectId: UUID, branch: String, day: Date) -> BranchBriefingItem? {
        fetchBranchBriefing(id: BranchBriefingRecord.makeId(projectId: projectId, branch: branch, day: Self.startOfDay(day)))?
            .toItem()
    }

    /// Every briefing recorded for `branch`, one per day it was worked on.
    func branchBriefingItems(projectId: UUID, branch: String) -> [BranchBriefingItem] {
        fetchBranchBriefings(projectId: projectId, branch: branch).map { $0.toItem() }
    }

    /// The whole branch story: every day's briefing merged oldest first.
    func combinedBranchBriefing(projectId: UUID, branch: String) -> String? {
        branchBriefingItems(projectId: projectId, branch: branch)
            .combinedBriefing(projectId: projectId, branch: branch)
    }

    func allBranchBriefingItems() -> [BranchBriefingItem] {
        let descriptor = FetchDescriptor<BranchBriefingRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toItem() }
    }

    /// Clear derived search and briefing data while retaining chats and tasks.
    func clearCachedRecords() throws {
        for row in try context.fetch(FetchDescriptor<ThreadSummaryRecord>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BranchBriefingRecord>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<ThreadEmbeddingChunk>()) { context.delete(row) }
        try context.save()
    }

    @discardableResult
    func deleteBriefingMetadata(excludingProjectIds knownProjectIds: Set<UUID>) -> (threadSummaries: Int, branchBriefings: Int) {
        let summaryRows = (try? context.fetch(FetchDescriptor<ThreadSummaryRecord>())) ?? []
        var threadDescriptor = FetchDescriptor<ChatThread>()
        threadDescriptor.propertiesToFetch = [\.id]
        let retainedThreadIds = Set(((try? context.fetch(threadDescriptor)) ?? []).map(\.id))
        let orphanedSummaries = summaryRows.filter {
            !knownProjectIds.contains($0.projectId) && !retainedThreadIds.contains($0.sessionId)
        }

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
    /// chunks) — whose project is no longer known.
    func pruneOrphanThreads(excludingProjectIds knownProjectIds: Set<UUID>) -> Int {
        let threadRows = (try? context.fetch(FetchDescriptor<ChatThread>())) ?? []
        let orphans = threadRows.filter { !knownProjectIds.contains($0.projectId) }
        let orphanIds = orphans.map(\.id)

        let orphanChunks = fetchOrphanEmbeddingChunks(excludingProjectIds: knownProjectIds)

        guard !orphans.isEmpty || !orphanChunks.isEmpty else { return 0 }

        for row in orphans { context.delete(row) }
        for id in orphanIds {
            deleteTodoSnapshotRow(sessionId: id)
            deleteFileEditRows(sessionId: id)
            deleteDetectedToolChangeRows(sessionId: id)
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
        updatedAt: Date = .now,
        createdAt: Date? = nil
    ) {
        if let existing = fetchThreadSummary(sessionId: sessionId) {
            existing.apply(projectId: projectId, branch: branch, title: title, summary: summary, updatedAt: updatedAt)
            if existing.createdAt == nil {
                existing.createdAt = createdAt ?? fetch(id: sessionId)?.createdAt ?? updatedAt
            }
        } else {
            context.insert(ThreadSummaryRecord(
                sessionId: sessionId,
                projectId: projectId,
                branch: branch,
                title: title,
                summary: summary,
                updatedAt: updatedAt,
                createdAt: createdAt ?? fetch(id: sessionId)?.createdAt ?? updatedAt
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
                updatedAt: seed.updatedAt,
                createdAt: fetch(id: sessionId)?.createdAt ?? seed.updatedAt
            ))
        }
        save()
    }

    /// Upsert the briefing for `branch` on the calendar day containing `day`
    /// (today by default). Each day a branch is worked on gets its own record.
    func upsertBranchBriefing(
        projectId: UUID,
        branch: String,
        day: Date = .now,
        briefing: String,
        updatedAt: Date = .now
    ) {
        let day = Self.startOfDay(day)
        let id = BranchBriefingRecord.makeId(projectId: projectId, branch: branch, day: day)
        if let existing = fetchBranchBriefing(id: id) {
            existing.apply(briefing: briefing, updatedAt: updatedAt)
        } else {
            context.insert(BranchBriefingRecord(
                projectId: projectId,
                branch: branch,
                day: day,
                briefing: briefing,
                updatedAt: updatedAt,
                lastSeenAt: updatedAt
            ))
        }
        save()
    }

    /// Removes every generated briefing for the branch (all days).
    @discardableResult
    func deleteBranchBriefing(projectId: UUID, branch: String) throws -> Bool {
        let rows = fetchBranchBriefings(projectId: projectId, branch: branch)
        guard !rows.isEmpty else { return false }
        for row in rows { context.delete(row) }
        try context.save()
        return true
    }

    /// Removes a single day's generated briefing.
    @discardableResult
    func deleteBranchBriefing(id: String) throws -> Bool {
        guard let row = fetchBranchBriefing(id: id) else { return false }
        context.delete(row)
        try context.save()
        return true
    }

    /// Mark a branch's briefings as recently observed, resetting the TTL used by
    /// `purgeStaleBranchBriefings`. No-op if no record exists.
    func touchBranchBriefing(projectId: UUID, branch: String, at date: Date = .now) {
        let rows = fetchBranchBriefings(projectId: projectId, branch: branch)
        guard !rows.isEmpty else { return }
        for row in rows { row.touch(at: date) }
        save()
    }

    /// Delete branch briefings whose `lastSeenAt` is older than `cutoff`.
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
    /// review dot survives a reload.
    func setReviewPassed(sessionId: String, passed: Bool) {
        let row = fetch(id: sessionId) ?? fetchByCliSessionId(sessionId)
        guard let row else { return }
        guard row.reviewPassed != passed else { return }
        row.reviewPassed = passed
        save()
    }

    /// Rehydrate the in-memory `reviewPassedBySession` map at launch.
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
    func renameId(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetch(id: oldId) else { return }
        if let existingAtNew = fetch(id: newId) {
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
        renameDetectedToolChanges(from: oldId, to: newId)
        renameQueueKey(from: oldId, to: newId)
        renamePlanDecisions(from: oldId, to: newId)
        renameHookStatus(from: oldId, to: newId)
        renameHookCards(from: oldId, to: newId)
        renameThreadSummary(from: oldId, to: newId)
        save()
    }

    /// Mark a thread row as archived (or restore it).
    @discardableResult
    func setArchived(id: String, archived: Bool, at date: Date = .now) -> ChatSession.Summary? {
        guard let row = fetch(id: id) else { return nil }
        row.isArchived = archived
        row.archivedAt = archived ? date : nil
        save()
        return row.toSummary()
    }

    func staleArchivedIds(olderThan cutoff: Date) -> [String] {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { row in
                row.isArchived == true && row.isPinned == false && row.archivedAt != nil && row.archivedAt! < cutoff
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map(\.id)
    }

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
        deleteDetectedToolChangeRows(sessionId: id)
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
                deleteDetectedToolChangeRows(sessionId: id)
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
                let allDetected = (try? context.fetch(FetchDescriptor<ToolDetectedChangeRecord>())) ?? []
                for row in allDetected { context.delete(row) }
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

    private func fetchBranchBriefing(id: String) -> BranchBriefingRecord? {
        var descriptor = FetchDescriptor<BranchBriefingRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchBranchBriefings(projectId: UUID, branch: String) -> [BranchBriefingRecord] {
        let descriptor = FetchDescriptor<BranchBriefingRecord>(
            predicate: #Predicate { $0.projectId == projectId && $0.branch == branch },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    func backfillThreadSummaryCreatedAt() {
        let descriptor = FetchDescriptor<ThreadSummaryRecord>(
            predicate: #Predicate { $0.createdAt == nil }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return }
        for row in rows {
            row.createdAt = fetch(id: row.sessionId)?.createdAt ?? row.updatedAt
        }
        save()
    }

    // MARK: - Todo Snapshots

    func fetchTodoSnapshot(sessionId: String) -> TodoSnapshot? {
        var descriptor = FetchDescriptor<TodoSnapshot>(predicate: #Predicate { $0.sessionId == sessionId })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func loadTodoProgressBySession() -> [String: ChatTodoProgress] {
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

    func loadTodoItemsBySession() -> [String: [TodoItem]] {
        let descriptor = FetchDescriptor<TodoSnapshot>(predicate: #Predicate { $0.total > 0 })
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.reduce(into: [:]) { result, row in
            result[row.sessionId] = row.items
        }
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

    @discardableResult
    func finalizeInterruptedCompletionChecks() -> [String] {
        let inProgress = TaskCompletionCheckLabel.inProgress
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.threadLabel == inProgress }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return [] }
        for row in rows {
            row.threadLabel = TaskCompletionCheckLabel.unverified
        }
        save()
        return rows.map(\.id)
    }

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

    func save() {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { logger.error("Save failed: \(error.localizedDescription)") }
    }
}
