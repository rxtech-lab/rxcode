import Foundation
import SwiftData
import ClarcCore
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
        let schema = Schema([ChatThread.self])
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
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Clarc", isDirectory: true)
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
        save()
    }

    func delete(id: String) {
        guard let row = fetch(id: id) else { return }
        context.delete(row)
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
            for row in rows { context.delete(row) }
            save()
        } catch {
            logger.error("deleteAll failed: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { logger.error("Save failed: \(error.localizedDescription)") }
    }
}
