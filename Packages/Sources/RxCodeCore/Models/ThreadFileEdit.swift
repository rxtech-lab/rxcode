import Foundation
import SwiftData

/// Persisted record of a single edited file within a chat thread. One row per
/// (sessionId, path). Each row aggregates every Edit/MultiEdit/Write hunk applied
/// to that path across all turns in the thread, so the "This thread" inspector
/// can show file-level edits without re-reading the full message log.
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
    /// Edit/MultiEdit/Write tool_use for this path. Fixed forever once set —
    /// the "before" side of the snapshot-pair diff. Optional for legacy rows
    /// persisted before snapshot capture was added.
    public var originalContent: String?
    /// Full file content re-read from disk after each successful edit
    /// tool_result for this path. Overwritten on every subsequent edit so the
    /// "after" side always reflects this thread's most recent committed state.
    /// Optional for legacy rows; consumers fall back to disk read / hunks.
    public var modifiedContent: String?

    public init(
        sessionId: String,
        path: String,
        name: String,
        hunks: [PreviewFile.EditHunk],
        containsWrite: Bool,
        originalContent: String? = nil,
        modifiedContent: String? = nil,
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
            modifiedContent: modifiedContent
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
