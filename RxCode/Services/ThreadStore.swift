import Foundation
import SwiftData
import RxCodeCore
import os

/// MainActor-scoped wrapper around the SwiftData store for `ChatThread`.
/// AppState is the only caller; all reads/writes happen on the main actor.
@MainActor
final class ThreadStore {
    private let logger = Logger(subsystem: "com.claudework", category: "ThreadStore")
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Convenience initializer creating its own `ModelContainer` rooted at the
    /// app's Application Support directory.
    static func make() -> ThreadStore {
        let schema = Schema([ChatThread.self, TodoSnapshot.self, ThreadFileEdit.self, QueuedMessageRecord.self, PlanDecisionRecord.self])
        let url = Self.storeURL()
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            return ThreadStore(context: ModelContext(container))
        } catch {
            // Fall back to an in-memory container so the app still launches.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: schema, configurations: [fallback])
            let store = ThreadStore(context: ModelContext(container))
            store.logger.error("Falling back to in-memory ChatThread store: \(error.localizedDescription)")
            return store
        }
    }

    private static func storeURL() -> URL {
        let fm = FileManager.default
        let dir = AppSupport.bundleScopedURL
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
            context.delete(row)
        } else {
            row.id = newId
            if row.cliSessionId == nil { row.cliSessionId = newId }
        }
        renameTodoSnapshot(from: oldId, to: newId)
        renameFileEdits(from: oldId, to: newId)
        renameQueueKey(from: oldId, to: newId)
        renamePlanDecisions(from: oldId, to: newId)
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
            }
            save()
        } catch {
            logger.error("deleteAll failed: \(error.localizedDescription)")
        }
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

    // MARK: - Thread File Edits

    func fetchFileEdits(sessionId: String) -> [ThreadFileEdit] {
        let descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.firstEditedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
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
    func appendFileEdit(
        sessionId: String,
        path: String,
        hunks: [PreviewFile.EditHunk],
        containsWrite: Bool
    ) {
        guard !hunks.isEmpty else { return }
        let name = (path as NSString).lastPathComponent
        if let existing = fetchFileEdit(sessionId: sessionId, path: path) {
            existing.append(hunks: hunks, containsWrite: containsWrite)
            existing.name = name
        } else {
            context.insert(ThreadFileEdit(
                sessionId: sessionId,
                path: path,
                name: name,
                hunks: hunks,
                containsWrite: containsWrite
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

    private func save() {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { logger.error("Save failed: \(error.localizedDescription)") }
    }
}
