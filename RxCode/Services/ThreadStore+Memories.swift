import Foundation
import SwiftData
import RxCodeCore

/// Memory-record CRUD for `ThreadStore`. Split out of `ThreadStore.swift` to
/// keep that file under the file-length limit; the persistence model and main
/// actor scoping are unchanged.
extension ThreadStore {
    // MARK: - Memories

    func loadAllMemories() -> [MemoryRecord] {
        let descriptor = FetchDescriptor<MemoryRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func loadAllMemorySnapshots() -> [MemoryVectorSnapshot] {
        loadAllMemories().map { $0.toVectorSnapshot() }
    }

    func fetchMemory(id: String) -> MemoryRecord? {
        var descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func upsertMemory(
        id: String?,
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        kind: String,
        scope: String,
        vector: Data,
        dim: Int
    ) -> MemoryItem {
        let memoryId = id ?? UUID().uuidString
        let now = Date()
        if let existing = fetchMemory(id: memoryId) {
            existing.apply(
                content: content,
                projectId: projectId,
                sessionId: sessionId,
                sourceMessageId: sourceMessageId,
                kind: kind,
                scope: scope,
                vector: vector,
                dim: dim,
                updatedAt: now
            )
            save()
            return existing.toItem()
        } else {
            let row = MemoryRecord(
                id: memoryId,
                content: content,
                projectId: projectId,
                sessionId: sessionId,
                sourceMessageId: sourceMessageId,
                createdAt: now,
                updatedAt: now,
                kind: kind,
                scope: scope,
                vector: vector,
                dim: dim
            )
            context.insert(row)
            save()
            return row.toItem()
        }
    }

    func touchMemories(ids: [String], at date: Date = .now) {
        guard !ids.isEmpty else { return }
        for id in ids {
            fetchMemory(id: id)?.touch(at: date)
        }
        save()
    }

    func deleteMemory(id: String) {
        guard let row = fetchMemory(id: id) else { return }
        context.delete(row)
        save()
    }

    func deleteAllMemories(projectId: UUID? = nil) {
        if let projectId {
            deleteMemoryRows(projectId: projectId)
        } else {
            let rows = (try? context.fetch(FetchDescriptor<MemoryRecord>())) ?? []
            for row in rows { context.delete(row) }
        }
        save()
    }

    private func deleteMemoryRows(projectId: UUID) {
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.projectId == projectId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
    }
}
