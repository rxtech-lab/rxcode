import Foundation
import SwiftData

/// Persisted record of a single edited file within a chat thread. One row per
/// (sessionId, path). Each row aggregates every Edit/MultiEdit/Write or
/// detected shell hunk applied to that path across all turns in the thread, so
/// the "This thread" inspector can show file-level edits without re-reading the
/// full message log.
@Model
public final class ThreadFileEdit {
    public var sessionId: String
    public var path: String
    public var name: String
    public var containsWrite: Bool
    public var hunksData: Data
    public var firstEditedAt: Date
    public var updatedAt: Date
    /// Full file content captured the first time this session's stream sees an
    /// Edit/MultiEdit/Write or shell mutation for this path. Fixed forever once
    /// set — the "before" side of the snapshot-pair diff. Optional for legacy rows.
    public var originalContent: String?
    /// Full file content captured after each successful edit in this thread.
    /// Optional for legacy rows; consumers fall back to disk read / hunks.
    public var modifiedContent: String?
    /// True when another thread modified this same file between two edits in
    /// this thread (optional for lightweight SwiftData migration).
    public var hasExternalInterleaving: Bool?
    /// True when the latest edit in this thread removed the file on disk.
    public var isDeleted: Bool?
    /// True when attribution overlapped ambiguously with another mutating thread.
    public var isAmbiguous: Bool?

    public init(
        sessionId: String,
        path: String,
        name: String,
        hunks: [PreviewFile.EditHunk],
        containsWrite: Bool,
        originalContent: String? = nil,
        modifiedContent: String? = nil,
        hasExternalInterleaving: Bool? = nil,
        isDeleted: Bool? = nil,
        isAmbiguous: Bool? = nil,
        firstEditedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.sessionId = sessionId
        self.path = path
        self.name = name
        self.containsWrite = containsWrite
        self.hunksData = Self.encode(hunks)
        self.originalContent = originalContent
        self.modifiedContent = modifiedContent
        self.hasExternalInterleaving = hasExternalInterleaving
        self.isDeleted = isDeleted
        self.isAmbiguous = isAmbiguous
        self.firstEditedAt = firstEditedAt
        self.updatedAt = updatedAt
    }

    public var hunks: [PreviewFile.EditHunk] {
        guard let decoded = try? JSONDecoder().decode([StoredHunk].self, from: hunksData) else {
            return []
        }
        return decoded.map { PreviewFile.EditHunk(oldString: $0.oldString, newString: $0.newString) }
    }

    public func append(hunks newHunks: [PreviewFile.EditHunk], containsWrite addWrite: Bool, at date: Date = .now) {
        var combined = self.hunks
        combined.append(contentsOf: newHunks)
        self.hunksData = Self.encode(combined)
        if addWrite { self.containsWrite = true }
        self.updatedAt = date
    }

    public func toSummary() -> FileEditSummary {
        FileEditSummary(
            path: path,
            name: name,
            hunks: hunks,
            containsWrite: containsWrite,
            originalContent: originalContent,
            modifiedContent: modifiedContent,
            hasExternalInterleaving: hasExternalInterleaving ?? false,
            isDeleted: isDeleted ?? false,
            isAmbiguous: isAmbiguous ?? false
        )
    }

    private static func encode(_ hunks: [PreviewFile.EditHunk]) -> Data {
        let stored = hunks.map { StoredHunk(oldString: $0.oldString, newString: $0.newString) }
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    private struct StoredHunk: Codable {
        let oldString: String
        let newString: String
    }
}
