import Foundation
import NaturalLanguage
import RxCodeCore
import os

actor MemoryService {
    /// User-global memories reuse the personal workspace's existing MemoryRecord table.
    /// One shared index makes edits/deletions visible to every workspace and pet immediately.
    static let userGlobal = MemoryService(globalOnly: true)
    @MainActor private static var personalStore: ThreadStore?
    @MainActor static func registerPersonalStore(_ store: ThreadStore) {
        if personalStore == nil { personalStore = store }
    }
    @MainActor private static func sharedPersonalStore() -> ThreadStore {
        if let personalStore { return personalStore }
        let store = ThreadStore.make(baseURL: AppWorkspace.personal.storageURL)
        personalStore = store
        return store
    }
    private let globalMemories: MemoryService?
    private var startup: Task<Void, Never>?
    private let globalOnly: Bool
    private var keepsGlobalRows = false

    init(globalMemories: MemoryService? = nil, globalOnly: Bool = false) {
        self.globalMemories = globalMemories; self.globalOnly = globalOnly
    }

    func startUserGlobal() async {
        if let startup { await startup.value; return }
        if didStart { return }
        let task = Task {
            let store = await Self.sharedPersonalStore()
            await self.load(threadStore: store, keepsGlobalRows: true)
        }
        startup = task
        await task.value
        startup = nil
    }

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

    func start(threadStore: ThreadStore, keepsGlobalRows: Bool = false) async {
        if let startup { await startup.value; return }
        guard !didStart else { return }
        let task = Task { await self.load(threadStore: threadStore, keepsGlobalRows: keepsGlobalRows) }
        startup = task
        await task.value
        startup = nil
    }

    private func load(threadStore: ThreadStore, keepsGlobalRows: Bool) async {
        didStart = true
        self.keepsGlobalRows = keepsGlobalRows
        self.threadStore = threadStore
        embedder = NLEmbedding.sentenceEmbedding(for: .english)
        wordEmbedder = NLEmbedding.wordEmbedding(for: .english)
        logger.info("start(): sentenceEmbedder=\(self.embedder != nil), wordEmbedder=\(self.wordEmbedder != nil)")

        await globalMemories?.startUserGlobal()
        let rows = await MainActor.run { threadStore.loadAllMemorySnapshots() }
        for row in rows {
            if globalOnly && row.item.scope != "global" { continue }
            if row.item.scope == "global", let globalMemories {
                if await globalMemories.importGlobal(row), !keepsGlobalRows {
                    await MainActor.run { threadStore.deleteMemory(id: row.item.id) }
                }
                continue
            }
            let vector = row.floatVector()
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
        let global = await globalMemories?.allMemories() ?? []
        return (entries.values.map(\.item) + global).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func importGlobal(_ snapshot: MemoryVectorSnapshot) async -> Bool {
        if entries[snapshot.item.id] != nil { return true }
        guard let threadStore else { return false }
        let item = snapshot.item
        let vector = snapshot.floatVector()
        let stored = await MainActor.run {
            threadStore.upsertMemory(id: item.id, content: item.content, projectId: nil,
                sessionId: item.sessionId, sourceMessageId: item.sourceMessageId, kind: item.kind,
                scope: "global", vector: MemoryRecord.encode(vector), dim: vector.count)
        }
        entries[stored.id] = Entry(item: stored, vector: vector)
        return true
    }

    func search(_ query: String, projectId: UUID?, limit: Int = 20, minScore: Float? = nil, scope: String? = nil, includePet: Bool = false) async -> [Hit] {
        let startedAt = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let elapsed = Date().timeIntervalSince(startedAt)
            logger.info("[Memory] search skipped queryChars=\(trimmed.count) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
            return []
        }

        let qvec = embed(trimmed)
        let ranked = entries.values.compactMap { entry -> Hit? in
            if entry.item.scope == "pet", scope == nil, !includePet { return nil }
            if let scope, entry.item.scope != scope { return nil }
            if let memoryProject = entry.item.projectId, memoryProject != projectId { return nil }
            let lexical: Float = entry.item.content.localizedCaseInsensitiveContains(trimmed) ? 1 : 0
            let score = max(qvec.map { dot($0, entry.vector) } ?? 0, lexical)
            if let minScore, score <= minScore {
                return nil
            }
            return Hit(item: entry.item, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(max(1, limit))

        let globalHits = await globalMemories?.search(query, projectId: projectId, limit: limit, minScore: minScore, scope: scope) ?? []
        let hits = Array((Array(ranked) + globalHits).sorted { $0.score > $1.score }.prefix(max(1, limit)))
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
        if globalOnly && entries[id] == nil { return }
        await globalMemories?.deleteMemory(id: id)
        entries.removeValue(forKey: id)
        guard let store = threadStore else { return }
        await MainActor.run { store.deleteMemory(id: id) }
    }

    private func removeIndex(id: String) { entries.removeValue(forKey: id) }

    func deleteAll(projectId: UUID? = nil) async {
        if globalOnly && projectId != nil { return }
        if projectId == nil { await globalMemories?.deleteAll() }
        if globalOnly {
            let ids = Array(entries.keys)
            entries.removeAll()
            if let threadStore { await MainActor.run { for id in ids { threadStore.deleteMemory(id: id) } } }
            return
        }
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
        if scope == "global", let globalMemories {
            let result = await globalMemories.upsertMemory(id: id, content: content, projectId: nil,
                sessionId: sessionId, sourceMessageId: sourceMessageId, kind: kind, scope: "global")
            if result != nil, let id {
                entries.removeValue(forKey: id)
                if !keepsGlobalRows, let threadStore { await MainActor.run { threadStore.deleteMemory(id: id) } }
            }
            return result
        }
        guard let store = threadStore else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let vector = embed(trimmed) ?? []
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
        if scope != "global", let id {
            if keepsGlobalRows { await globalMemories?.removeIndex(id: id) }
            else { await globalMemories?.deleteMemory(id: id) }
        }
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
