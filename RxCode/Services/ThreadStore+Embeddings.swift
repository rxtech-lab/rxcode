import Foundation
import SwiftData
import RxCodeCore

// MARK: - Thread Embedding Chunks

@MainActor
extension ThreadStore {
    func loadAllEmbeddingChunks() -> [ThreadEmbeddingChunk] {
        let descriptor = FetchDescriptor<ThreadEmbeddingChunk>()
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Embedding chunks belonging to projects that are no longer known. Backs
    /// the launch-time orphan sweep in `pruneOrphanThreads`.
    ///
    /// Two steps on purpose: the first fetch asks for `projectId` only, so the
    /// common "nothing to prune" case never pulls a vector blob off disk; the
    /// second materializes just the rows that have to be deleted.
    func fetchOrphanEmbeddingChunks(excludingProjectIds knownProjectIds: Set<UUID>) -> [ThreadEmbeddingChunk] {
        var projectsDescriptor = FetchDescriptor<ThreadEmbeddingChunk>()
        projectsDescriptor.propertiesToFetch = [\.projectId]
        let chunkProjectIds = Set(((try? context.fetch(projectsDescriptor)) ?? []).map(\.projectId))
        let orphanProjectIds = Array(chunkProjectIds.subtracting(knownProjectIds))
        guard !orphanProjectIds.isEmpty else { return [] }

        let descriptor = FetchDescriptor<ThreadEmbeddingChunk>(
            predicate: #Predicate { orphanProjectIds.contains($0.projectId) }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func loadEmbeddingChunks(threadId: String) -> [ThreadEmbeddingChunk] {
        let descriptor = FetchDescriptor<ThreadEmbeddingChunk>(
            predicate: #Predicate { $0.threadId == threadId },
            sortBy: [SortDescriptor(\.chunkIndex, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Replace all chunks for a thread atomically. Old rows are deleted first
    /// so re-indexing cannot leave orphans behind.
    func replaceEmbeddingChunks(threadId: String, chunks: [ThreadEmbeddingChunk]) {
        deleteEmbeddingChunkRows(threadId: threadId)
        for chunk in chunks {
            context.insert(chunk)
        }
        save()
    }

    func deleteEmbeddingChunks(threadId: String) {
        deleteEmbeddingChunkRows(threadId: threadId)
        save()
    }

    /// Wipe every persisted embedding chunk across all threads.
    func deleteAllEmbeddingChunks() {
        let descriptor = FetchDescriptor<ThreadEmbeddingChunk>()
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
        save()
    }

    func deleteEmbeddingChunkRows(threadId: String) {
        let descriptor = FetchDescriptor<ThreadEmbeddingChunk>(
            predicate: #Predicate { $0.threadId == threadId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
    }
}
