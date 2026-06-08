import Foundation
import NaturalLanguage
import RxCodeCore
import os

actor MemoryService {
    struct Hit: Sendable, Equatable, Identifiable {
        let item: MemoryItem
        let score: Float
        var id: String { item.id }
    }

    private struct Entry {
        var item: MemoryItem
        var vector: [Float]
    }

    private let logger = Logger(subsystem: "com.claudework", category: "MemoryService")
    private var entries: [String: Entry] = [:]
    private var embedder: NLEmbedding?
    private var wordEmbedder: NLEmbedding?
    private var threadStore: ThreadStore?
    private var didStart = false

    func start(threadStore: ThreadStore) async {
        guard !didStart else { return }
        didStart = true
        self.threadStore = threadStore
        embedder = NLEmbedding.sentenceEmbedding(for: .english)
        wordEmbedder = NLEmbedding.wordEmbedding(for: .english)
        logger.info("start(): sentenceEmbedder=\(self.embedder != nil), wordEmbedder=\(self.wordEmbedder != nil)")

        let rows = await MainActor.run { threadStore.loadAllMemorySnapshots() }
        for row in rows {
            let vector = row.floatVector()
            guard !vector.isEmpty else { continue }
            entries[row.item.id] = Entry(item: row.item, vector: vector)
        }
        logger.info("Loaded \(rows.count) memory rows, indexed=\(self.entries.count)")
    }

    func restart(threadStore: ThreadStore) async {
        entries.removeAll()
        didStart = false
        self.threadStore = nil
        await start(threadStore: threadStore)
    }

    func allMemories() async -> [MemoryItem] {
        entries.values
            .map(\.item)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func search(_ query: String, projectId: UUID?, limit: Int = 20, minScore: Float? = nil) async -> [Hit] {
        let startedAt = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let qvec = embed(trimmed) else {
            let elapsed = Date().timeIntervalSince(startedAt)
            logger.info("[Memory] search skipped queryChars=\(trimmed.count) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
            return []
        }

        let ranked = entries.values.compactMap { entry -> Hit? in
            if let memoryProject = entry.item.projectId,
               let projectId,
               memoryProject != projectId {
                return nil
            }
            let score = dot(qvec, entry.vector)
            if let minScore, score <= minScore {
                return nil
            }
            return Hit(item: entry.item, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(max(1, limit))

        let hits = Array(ranked)
        if let store = threadStore {
            let ids = hits.map(\.item.id)
            await MainActor.run { store.touchMemories(ids: ids) }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        logger.info("[Memory] search queryChars=\(trimmed.count) entries=\(self.entries.count) hits=\(hits.count) minScore=\(minScore.map { String(format: "%.2f", $0) } ?? "<none>", privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
        return hits
    }

    @discardableResult
    func addMemory(
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        kind: String = "fact",
        scope: String = "project"
    ) async -> MemoryItem? {
        await upsertMemory(
            id: nil,
            content: content,
            projectId: projectId,
            sessionId: sessionId,
            sourceMessageId: sourceMessageId,
            kind: kind,
            scope: scope
        )
    }

    @discardableResult
    func updateMemory(
        id: String,
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        kind: String,
        scope: String
    ) async -> MemoryItem? {
        await upsertMemory(
            id: id,
            content: content,
            projectId: projectId,
            sessionId: sessionId,
            sourceMessageId: sourceMessageId,
            kind: kind,
            scope: scope
        )
    }

    func deleteMemory(id: String) async {
        entries.removeValue(forKey: id)
        guard let store = threadStore else { return }
        await MainActor.run { store.deleteMemory(id: id) }
    }

    func deleteAll(projectId: UUID? = nil) async {
        if let projectId {
            entries = entries.filter { $0.value.item.projectId != projectId }
        } else {
            entries.removeAll()
        }
        guard let store = threadStore else { return }
        await MainActor.run { store.deleteAllMemories(projectId: projectId) }
    }

    @discardableResult
    private func upsertMemory(
        id: String?,
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        kind: String,
        scope: String
    ) async -> MemoryItem? {
        guard let store = threadStore else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let vector = embed(trimmed) else { return nil }
        let encoded = MemoryRecord.encode(vector)
        let item = await MainActor.run {
            store.upsertMemory(
                id: id,
                content: trimmed,
                projectId: projectId,
                sessionId: sessionId,
                sourceMessageId: sourceMessageId,
                kind: kind,
                scope: scope,
                vector: encoded,
                dim: vector.count
            )
        }
        entries[item.id] = Entry(item: item, vector: vector)
        return item
    }

    private func embed(_ text: String) -> [Float]? {
        if let embedder, let vec = embedder.vector(for: text) {
            return normalise(vec.map { Float($0) })
        }
        guard let wordEmbedder else { return nil }
        let tokens = tokenize(text)
        var sum: [Float] = Array(repeating: 0, count: wordEmbedder.dimension)
        var count = 0
        for token in tokens {
            guard let v = wordEmbedder.vector(for: token) else { continue }
            for (i, x) in v.enumerated() where i < sum.count {
                sum[i] += Float(x)
            }
            count += 1
        }
        guard count > 0 else { return nil }
        let inv = 1.0 / Float(count)
        for i in 0..<sum.count { sum[i] *= inv }
        return normalise(sum)
    }

    private func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lower
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: lower.startIndex..<lower.endIndex) { range, _ in
            tokens.append(String(lower[range]))
            return true
        }
        return tokens
    }

    private func normalise(_ vec: [Float]) -> [Float] {
        var sum: Float = 0
        for x in vec { sum += x * x }
        let n = sum.squareRoot()
        guard n > 0 else { return vec }
        let inv = 1.0 / n
        return vec.map { $0 * inv }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        var s: Float = 0
        for i in 0..<count { s += a[i] * b[i] }
        return s
    }
}
