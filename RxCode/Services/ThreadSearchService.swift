import Foundation
import NaturalLanguage
import RxCodeCore
import os

/// On-device semantic search across past chat threads. Embeds thread content
/// when the thread finalizes and stores L2-normalised vectors in SwiftData via
/// `ThreadStore`. Search runs in-memory using cosine similarity (which reduces
/// to a dot product on normalised vectors), then collapses to one hit per
/// thread (max-scoring chunk wins) and groups by project.
actor ThreadSearchService {

    // MARK: - Public types

    struct Hit: Sendable, Equatable {
        let threadId: String
        let projectId: UUID
        let score: Float
        let snippet: String
        let chunkIndex: Int
    }

    struct Group: Sendable, Equatable {
        let projectId: UUID
        let hits: [Hit]
    }

    /// Literal substring match inside the currently-open thread. Distinct from
    /// `Hit` because we surface the matched message rather than a cosine-ranked
    /// chunk, and we keep the surrounding text window so the overlay can
    /// render a highlight.
    struct InThreadHit: Sendable, Equatable, Identifiable {
        let messageId: UUID
        let role: Role
        let snippet: String
        /// Range of the matched substring within `snippet`.
        let matchRange: Range<String.Index>
        let timestamp: Date
        var id: UUID { messageId }
    }

    // MARK: - Stored types

    private struct Chunk {
        let index: Int
        let projectId: UUID
        let text: String
        let vector: [Float]
    }

    // MARK: - State

    private let logger = Logger(subsystem: "com.claudework", category: "ThreadSearchService")
    private var index: [String: [Chunk]] = [:]
    private var embedder: NLEmbedding?
    private var wordEmbedder: NLEmbedding?
    private var threadStore: ThreadStore?
    private var didStart = false

    /// Maximum characters per chunk. Sentence-embedding accepts longer input
    /// but quality degrades for very long passages.
    private let chunkSize = 480
    /// Backfill version sentinel. Bump when chunking or embedding model changes.
    private let backfillVersion = 2
    private let backfillKey = "com.idealapp.RxCode.searchIndex.backfillVersion"

    init() {}

    // MARK: - Lifecycle

    /// Load any existing chunk rows into memory. Cheap: ~2KB per chunk.
    func start(threadStore: ThreadStore) async {
        guard !didStart else {
            logger.info("start() called again — already initialised, ignoring")
            return
        }
        didStart = true
        self.threadStore = threadStore
        embedder = NLEmbedding.sentenceEmbedding(for: .english)
        wordEmbedder = NLEmbedding.wordEmbedding(for: .english)
        logger.info("start(): sentenceEmbedder=\(self.embedder != nil), wordEmbedder=\(self.wordEmbedder != nil)")
        if embedder == nil && wordEmbedder == nil {
            logger.error("Both sentence and word embeddings unavailable; search disabled")
            return
        }
        let rows = await MainActor.run { threadStore.loadAllEmbeddingChunks() }
        for row in rows {
            let chunk = Chunk(
                index: row.chunkIndex,
                projectId: row.projectId,
                text: row.text,
                vector: row.floatVector()
            )
            index[row.threadId, default: []].append(chunk)
        }
        for key in index.keys {
            index[key]?.sort { $0.index < $1.index }
        }
        logger.info("Loaded \(rows.count) embedding chunks across \(self.index.count) threads")
    }

    // MARK: - Indexing

    /// Index a thread's content. Replaces any prior chunks for that thread.
    /// Safe to call multiple times — re-indexing is idempotent.
    func indexThread(_ session: ChatSession) async {
        guard let store = threadStore else {
            logger.info("Skip index \(session.id, privacy: .public): threadStore not set (start() not called?)")
            return
        }
        guard embedder != nil || wordEmbedder != nil else {
            logger.info("Skip index \(session.id, privacy: .public): no embedder available")
            return
        }
        // Skip threads with no real content (placeholder rows, empty new chats).
        let texts = chunkTexts(for: session)
        guard !texts.isEmpty else {
            logger.info("Skip index \(session.id, privacy: .public): no chunkable content (messages=\(session.messages.count), title=\"\(session.title, privacy: .public)\")")
            await MainActor.run { store.deleteEmbeddingChunks(threadId: session.id) }
            index.removeValue(forKey: session.id)
            return
        }

        var newChunks: [Chunk] = []
        var rows: [ThreadEmbeddingChunk] = []
        var embedFailures = 0
        for (i, text) in texts.enumerated() {
            guard let vec = embed(text) else {
                embedFailures += 1
                continue
            }
            newChunks.append(Chunk(index: i, projectId: session.projectId, text: text, vector: vec))
            rows.append(ThreadEmbeddingChunk(
                id: ThreadEmbeddingChunk.makeId(threadId: session.id, index: i),
                threadId: session.id,
                projectId: session.projectId,
                chunkIndex: i,
                text: text,
                vector: ThreadEmbeddingChunk.encode(vec),
                dim: vec.count,
                updatedAt: .now
            ))
        }

        if newChunks.isEmpty {
            logger.error("Failed to index \(session.id, privacy: .public): all \(texts.count) chunk(s) failed to embed")
            return
        }

        index[session.id] = newChunks
        let threadId = session.id
        let snapshot = rows
        await MainActor.run {
            store.replaceEmbeddingChunks(threadId: threadId, chunks: snapshot)
        }
        logger.info("Indexed thread \(session.id, privacy: .public): \(newChunks.count) chunks (\(embedFailures) embed failures, \(session.messages.count) messages)")
    }

    /// Force a full reindex of every thread. Clears the in-memory index, wipes
    /// persisted chunks, resets the backfill sentinel, and re-embeds everything.
    /// Reports progress via the optional callback so the UI can show a spinner.
    func reindexAll(
        loadAll: @MainActor @Sendable () -> [ChatSession.Summary],
        loadFull: @MainActor @Sendable (ChatSession.Summary) async -> ChatSession?,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async {
        guard let store = threadStore else {
            logger.error("Reindex aborted: threadStore not set")
            return
        }
        logger.info("Reindex starting: clearing index and embedding chunk store")
        index.removeAll()
        await MainActor.run { store.deleteAllEmbeddingChunks() }
        UserDefaults.standard.removeObject(forKey: backfillKey)

        let summaries = await MainActor.run { loadAll() }
        let total = summaries.count
        logger.info("Reindex: \(total) thread summaries to embed")
        var done = 0
        var loadFailed = 0
        for summary in summaries {
            if let full = await loadFull(summary) {
                await indexThread(full)
            } else {
                loadFailed += 1
                logger.info("Reindex: failed to load full session \(summary.id, privacy: .public)")
            }
            done += 1
            progress?(done, total)
            if done % 8 == 0 { await Task.yield() }
        }
        UserDefaults.standard.set(backfillVersion, forKey: backfillKey)
        logger.info("Reindex complete: processed=\(done), loadFailed=\(loadFailed), total=\(total)")
    }

    func removeThread(id: String) async {
        index.removeValue(forKey: id)
        guard let store = threadStore else { return }
        await MainActor.run { store.deleteEmbeddingChunks(threadId: id) }
    }

    func removeProject(id: UUID) async {
        for (threadId, chunks) in index where chunks.first?.projectId == id {
            index.removeValue(forKey: threadId)
        }
        // ThreadStore.deleteAll(projectId:) already purges chunks at the same
        // time it removes the threads, so the disk side is handled there.
    }

    /// Drop every in-memory chunk whose project is no longer known. The disk
    /// rows are purged separately at launch (`ThreadStore.pruneOrphanThreads`);
    /// this keeps the live index consistent regardless of whether `start()`
    /// loaded before or after that prune ran.
    func pruneOrphans(knownProjectIds: Set<UUID>) async {
        let before = index.count
        for (threadId, chunks) in index {
            guard let projectId = chunks.first?.projectId else { continue }
            if !knownProjectIds.contains(projectId) {
                index.removeValue(forKey: threadId)
            }
        }
        let removed = before - index.count
        if removed > 0 {
            logger.info("Pruned \(removed) orphan thread(s) from in-memory search index")
        }
    }

    // MARK: - Search

    /// Return up to `limit` thread hits, grouped by project, sorted by descending score.
    func search(_ query: String, limit: Int = 50) async -> [Group] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let qvec = embed(trimmed) else { return [] }

        struct Best { var score: Float; var chunk: Chunk }
        var bestByThread: [String: Best] = [:]

        for (threadId, chunks) in index {
            for chunk in chunks {
                let score = dot(qvec, chunk.vector)
                if let prior = bestByThread[threadId] {
                    if score > prior.score {
                        bestByThread[threadId] = Best(score: score, chunk: chunk)
                    }
                } else {
                    bestByThread[threadId] = Best(score: score, chunk: chunk)
                }
            }
        }

        let ranked = bestByThread
            .map { (threadId, best) in
                Hit(
                    threadId: threadId,
                    projectId: best.chunk.projectId,
                    score: best.score,
                    snippet: best.chunk.text,
                    chunkIndex: best.chunk.index
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)

        // Group by project, preserving rank order within each group and
        // ordering groups by their best score.
        var groups: [UUID: [Hit]] = [:]
        var groupOrder: [UUID] = []
        for hit in ranked {
            if groups[hit.projectId] == nil { groupOrder.append(hit.projectId) }
            groups[hit.projectId, default: []].append(hit)
        }
        return groupOrder.map { Group(projectId: $0, hits: groups[$0] ?? []) }
    }

    // MARK: - Backfill

    /// Index every thread that does not have any cached chunks yet. Honoured
    /// once per `backfillVersion` (bump the constant if the embedding/chunking
    /// strategy changes and old vectors should be discarded).
    func backfillIfNeeded(
        loadAll: @MainActor @Sendable () -> [ChatSession.Summary],
        loadFull: @MainActor @Sendable (ChatSession.Summary) async -> ChatSession?
    ) async {
        guard threadStore != nil else {
            logger.info("Backfill skipped: threadStore not set")
            return
        }
        let stored = UserDefaults.standard.integer(forKey: backfillKey)
        guard stored < backfillVersion else {
            logger.info("Backfill skipped: already ran at version \(stored) (current=\(self.backfillVersion))")
            return
        }

        let summaries = await MainActor.run { loadAll() }
        logger.info("Backfill starting: \(summaries.count) thread summaries to evaluate")
        var done = 0
        var alreadyIndexed = 0
        var loadFailed = 0
        for summary in summaries {
            if !index[summary.id, default: []].isEmpty {
                alreadyIndexed += 1
                continue
            }
            guard let full = await loadFull(summary) else {
                loadFailed += 1
                logger.info("Backfill: failed to load full session \(summary.id, privacy: .public)")
                continue
            }
            await indexThread(full)
            done += 1
            // Yield occasionally so we don't starve the cooperative pool.
            if done % 8 == 0 { await Task.yield() }
        }
        UserDefaults.standard.set(backfillVersion, forKey: backfillKey)
        logger.info("Search backfill complete: indexed=\(done), alreadyIndexed=\(alreadyIndexed), loadFailed=\(loadFailed), total=\(summaries.count)")
    }

    // MARK: - Chunking

    /// Build the list of plain-text chunks to embed for a session. The first
    /// chunk is always the title so a title-only match still scores well; the
    /// rest are message text packed into ~`chunkSize`-character windows on
    /// message boundaries. Tool-call blocks are skipped — they're noisy and
    /// don't reflect the user's intent.
    private func chunkTexts(for session: ChatSession) -> [String] {
        var chunks: [String] = []
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != ChatSession.defaultTitle {
            chunks.append(trimmedTitle)
        }

        var buffer = ""
        for message in session.messages {
            let raw = message.blocks.compactMap(\.text).joined(separator: " ")
            guard !raw.isEmpty else { continue }
            let cleaned = ChatSession.stripAttachmentMarkers(from: raw)
            guard !cleaned.isEmpty else { continue }

            let prefix = (message.role == .user) ? "User: " : "Assistant: "
            let piece = prefix + cleaned

            if buffer.isEmpty {
                buffer = piece
            } else if buffer.count + piece.count + 1 <= chunkSize {
                buffer += "\n" + piece
            } else {
                chunks.append(buffer)
                buffer = piece
            }

            // Hard-split overlong individual messages so we don't blow past the
            // window by an entire long assistant reply.
            while buffer.count > chunkSize {
                let cutIndex = buffer.index(buffer.startIndex, offsetBy: chunkSize)
                chunks.append(String(buffer[..<cutIndex]))
                buffer = String(buffer[cutIndex...])
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }

        // First-message-only threads: if the only chunk is the title, that's still useful.
        // If nothing at all, return empty so the caller skips indexing.
        return chunks
    }

    // MARK: - Embedding

    private func embed(_ text: String) -> [Float]? {
        if let embedder, let vec = embedder.vector(for: text) {
            return normalise(vec.map { Float($0) })
        }
        // Word-level fallback: average word vectors. Skip terms with no vector.
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

    // MARK: - In-Thread Search

    /// Case-insensitive literal full-text search across the messages of an
    /// already-open thread. Produces one hit per matching message, in chat
    /// order, with a windowed snippet around the first match.
    nonisolated static func searchInThread(
        _ query: String,
        in messages: [ChatMessage],
        snippetRadius: Int = 60,
        limit: Int = 40
    ) -> [InThreadHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var hits: [InThreadHit] = []
        for message in messages {
            let raw = message.blocks.compactMap(\.text).joined(separator: " ")
            guard !raw.isEmpty else { continue }
            let cleaned = ChatSession.stripAttachmentMarkers(from: raw)
            guard !cleaned.isEmpty else { continue }

            guard let match = cleaned.range(of: trimmed, options: .caseInsensitive) else { continue }

            let (snippet, snippetRange) = makeSnippet(text: cleaned, match: match, radius: snippetRadius)
            hits.append(InThreadHit(
                messageId: message.id,
                role: message.role,
                snippet: snippet,
                matchRange: snippetRange,
                timestamp: message.timestamp
            ))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Build a `±radius` character window around `match` and return the snippet
    /// along with the matched range translated into the snippet's index space.
    /// Adds an ellipsis when either edge of the source string was clipped.
    private static func makeSnippet(
        text: String,
        match: Range<String.Index>,
        radius: Int
    ) -> (String, Range<String.Index>) {
        let lowerOffset = text.distance(from: text.startIndex, to: match.lowerBound)
        let upperOffset = text.distance(from: text.startIndex, to: match.upperBound)
        let total = text.count

        let startOffset = max(0, lowerOffset - radius)
        let endOffset = min(total, upperOffset + radius)
        let startIndex = text.index(text.startIndex, offsetBy: startOffset)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)

        var snippet = String(text[startIndex..<endIndex])
        var matchLowerInSnippet = lowerOffset - startOffset
        var matchUpperInSnippet = upperOffset - startOffset

        if startOffset > 0 {
            let prefix = "… "
            snippet = prefix + snippet
            matchLowerInSnippet += prefix.count
            matchUpperInSnippet += prefix.count
        }
        if endOffset < total {
            snippet += " …"
        }

        let lower = snippet.index(snippet.startIndex, offsetBy: matchLowerInSnippet)
        let upper = snippet.index(snippet.startIndex, offsetBy: matchUpperInSnippet)
        return (snippet, lower..<upper)
    }
}
