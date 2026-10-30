import Foundation

public enum CodingSessionRating: String, Codable, CaseIterable, Sendable {
    case good, neutral, bad
}

public struct CodingAnalyticsSession: Codable, Sendable, Identifiable {
    public struct ModelSelection: Codable, Sendable, Equatable {
        public var turnID: UUID
        public var provider: String
        public var acpClientID: String?
        public var model: String?
        public var selectedAt: Date
    }

    public struct Turn: Codable, Sendable, Identifiable {
        public var id: UUID
        public var prompts: [String]
        public var startedAt: Date
        public var endedAt: Date?
        public var recordingStopped: Bool?
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheCreationTokens: Int?
        public var cacheReadTokens: Int?
        public var usageLimits: [CodingUsageLimitSnapshot]?
        public var usageSamples: Int = 0
    }

    public var id: String
    public var projectID: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var models: [ModelSelection] = []
    public var turns: [Turn] = []
    public var rating: CodingSessionRating?

    /// Archive-relative path of the chat history for the session at `index` in an export.
    /// Numeric names prevent session IDs from becoming filesystem paths.
    public static func historyFilePath(index: Int) -> String {
        "sessions/" + String(format: "%06d.json", index + 1)
    }

    /// Elapsed time across the recorded conversation, including time between turns.
    public var elapsedSeconds: Double? { endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    public var activeSeconds: Double {
        turns.reduce(0) { $0 + max(0, ($1.endedAt ?? $1.startedAt).timeIntervalSince($1.startedAt)) }
    }
    public var totalReportedTokens: Int? {
        guard turns.contains(where: { $0.usageSamples > 0 }) else { return nil }
        return turns.reduce(0) {
            $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0)
                + ($1.cacheCreationTokens ?? 0) + ($1.cacheReadTokens ?? 0)
        }
    }
}

/// Separate, local-only data store. Deletion also invalidates in-flight turns:
/// late result events cannot recreate deleted records.
public actor CodingAnalyticsStore {
    private struct ExportSession: Encodable {
        let session: CodingAnalyticsSession
        let historyFile: String
        private enum Metrics: String, CodingKey { case historyFile, elapsedSeconds, activeSeconds, totalReportedTokens }
        func encode(to encoder: any Encoder) throws {
            try session.encode(to: encoder)
            var metrics = encoder.container(keyedBy: Metrics.self)
            try metrics.encode(historyFile, forKey: .historyFile)
            try metrics.encodeIfPresent(session.elapsedSeconds, forKey: .elapsedSeconds)
            try metrics.encode(session.activeSeconds, forKey: .activeSeconds)
            try metrics.encodeIfPresent(session.totalReportedTokens, forKey: .totalReportedTokens)
        }
    }

    private struct Export: Encodable {
        var schemaVersion = 1
        var exportedAt: Date
        var sessions: [ExportSession]
    }

    private let url: URL
    private var sessions: [CodingAnalyticsSession]?

    public init(url: URL) { self.url = url }

    private func load() throws -> [CodingAnalyticsSession] {
        if let sessions { return sessions }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoded = try JSONDecoder().decode([CodingAnalyticsSession].self, from: Data(contentsOf: url))
        sessions = decoded
        return decoded
    }

    private func save(_ records: [CodingAnalyticsSession]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        sessions = records
    }

    public func begin(threadID: String, projectID: UUID, turnID: UUID, prompt: String?,
                      provider: String, clientID: String?, model: String?, usageLimits: CodingUsageLimitSnapshot? = nil, now: Date = .now) throws {
        var records = try load()
        let index = records.firstIndex { $0.id == threadID } ?? records.count
        if index == records.count {
            guard prompt != nil else { return }
            records.append(.init(id: threadID, projectID: projectID, startedAt: now))
        }
        guard !records[index].turns.contains(where: { $0.id == turnID }) else { return }
        records[index].endedAt = nil
        records[index].turns.append(.init(id: turnID, prompts: prompt.map { [$0] } ?? [], startedAt: now, usageLimits: usageLimits.map { [$0] }))
        records[index].models.append(.init(turnID: turnID, provider: provider, acpClientID: clientID, model: model, selectedAt: now))
        try save(records)
    }

    public func update(turnID: UUID, prompt: String? = nil, model: String? = nil,
                       usage: UsageInfo? = nil, usageLimits: CodingUsageLimitSnapshot? = nil, now: Date = .now) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.turns.contains { $0.id == turnID } }),
              let turn = records[index].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let last = records[index].models.last { $0.turnID == turnID }
        let modelChanged = model != nil && last?.model != model
        guard prompt != nil || usage != nil || modelChanged || usageLimits != nil else { return }
        if let prompt { records[index].turns[turn].prompts.append(prompt) }
        if modelChanged, let model, let last {
            records[index].models.append(.init(turnID: turnID, provider: last.provider, acpClientID: last.acpClientID,
                                               model: model, selectedAt: now))
        }
        if let usageLimits {
            records[index].turns[turn].usageLimits = (records[index].turns[turn].usageLimits ?? []) + [usageLimits]
        }
        if let usage {
            records[index].turns[turn].usageSamples += 1
            records[index].turns[turn].inputTokens = (records[index].turns[turn].inputTokens ?? 0) + usage.inputTokens
            records[index].turns[turn].outputTokens = (records[index].turns[turn].outputTokens ?? 0) + usage.outputTokens
            records[index].turns[turn].cacheCreationTokens = (records[index].turns[turn].cacheCreationTokens ?? 0) + usage.cacheCreationInputTokens
            records[index].turns[turn].cacheReadTokens = (records[index].turns[turn].cacheReadTokens ?? 0) + usage.cacheReadInputTokens
        }
        try save(records)
    }

    public func finish(turnID: UUID, threadID: String, usageLimits: CodingUsageLimitSnapshot? = nil, now: Date = .now) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.turns.contains { $0.id == turnID } }),
              let turn = records[index].turns.firstIndex(where: { $0.id == turnID }) else { return }
        if records[index].id != threadID {
            try redirect(from: records[index].id, to: threadID)
            try finish(turnID: turnID, threadID: threadID, usageLimits: usageLimits, now: now)
            return
        }
        if let usageLimits {
            records[index].turns[turn].usageLimits = (records[index].turns[turn].usageLimits ?? []) + [usageLimits]
        }
        records[index].turns[turn].endedAt = now
        records[index].endedAt = records[index].turns.allSatisfy { $0.endedAt != nil }
            ? records[index].turns.compactMap(\.endedAt).max() : nil
        try save(records)
    }

    public func stopRecording(turnIDs: Set<UUID>, now: Date) throws {
        guard !turnIDs.isEmpty else { return }
        var records = try load()
        for index in records.indices {
            for turn in records[index].turns.indices where turnIDs.contains(records[index].turns[turn].id) {
                records[index].turns[turn].endedAt = now
                records[index].turns[turn].recordingStopped = true
            }
            records[index].endedAt = records[index].turns.allSatisfy { $0.endedAt != nil }
                ? records[index].turns.compactMap(\.endedAt).max() : nil
        }
        try save(records)
    }

    public func redirect(from oldID: String, to newID: String) throws {
        guard oldID != newID else { return }
        var records = try load()
        guard let old = records.firstIndex(where: { $0.id == oldID }) else { return }
        var moved = records.remove(at: old)
        moved.id = newID
        if let existing = records.firstIndex(where: { $0.id == newID }) {
            let previous = records.remove(at: existing)
            moved.startedAt = min(moved.startedAt, previous.startedAt)
            moved.turns = (previous.turns + moved.turns).sorted { $0.startedAt < $1.startedAt }
            moved.models = (previous.models + moved.models).sorted { $0.selectedAt < $1.selectedAt }
            moved.rating = moved.rating ?? previous.rating
        }
        moved.endedAt = moved.turns.allSatisfy { $0.endedAt != nil } ? moved.turns.compactMap(\.endedAt).max() : nil
        records.append(moved)
        try save(records)
    }

    public func session(_ id: String) throws -> CodingAnalyticsSession? {
        try load().first { $0.id == id }
    }

    public func rate(threadID: String, rating: CodingSessionRating?) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == threadID }) else { return }
        records[index].rating = rating
        try save(records)
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        sessions = []
    }

    public func exportSnapshot() throws -> (analytics: Data, sessions: [CodingAnalyticsSession]) {
        (try export(), try load())
    }

    public func export() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(exportedAt: .now, sessions: load().enumerated().map {
            ExportSession(session: $1, historyFile: CodingAnalyticsSession.historyFilePath(index: $0))
        }))
    }
}
