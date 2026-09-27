import Foundation
import SwiftData
import RxCodeCore

/// Queued-message CRUD for `ThreadStore`. Split out of `ThreadStore.swift` to
/// keep that file under the file-length limit; the persistence model and main
/// actor scoping are unchanged.
extension ThreadStore {
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

    func deleteQueueRows(sessionKey: String) {
        let descriptor = FetchDescriptor<QueuedMessageRecord>(
            predicate: #Predicate { $0.sessionKey == sessionKey }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
    }
}
