import Foundation
import RxCodeCore

// MARK: - Thread changes

/// Mobile-initiated request for the change overview of a thread: every file
/// edited in the thread session plus the project's uncommitted git changes.
/// The desktop is the authoritative source for both (SwiftData edit history and
/// the working tree), so it builds the whole `ThreadChangesResultPayload`.
public struct ThreadChangesRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let sessionID: String

    public init(clientRequestID: UUID = UUID(), sessionID: String) {
        self.clientRequestID = clientRequestID
        self.sessionID = sessionID
    }
}

/// One old/new replacement pair. Wire form of `PreviewFile.EditHunk`, which is
/// not itself `Codable`.
public struct SyncEditHunk: Codable, Sendable, Equatable {
    public let oldString: String
    public let newString: String

    public init(oldString: String, newString: String) {
        self.oldString = oldString
        self.newString = newString
    }
}

/// Aggregated edits to a single file across a whole thread session. Wire form
/// of `FileEditSummary`.
public struct SyncFileEdit: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    /// True if any contributing tool was Write — old content was overwritten.
    public let containsWrite: Bool
    public let hunks: [SyncEditHunk]
    /// Optional full-file before/after diff for mobile detail views. Older
    /// desktop builds omit this and mobile falls back to `hunks`.
    public let fullFileDiff: String?
    /// Pre-edit snapshot ("before" side of the snapshot-pair diff). Optional —
    /// older desktop builds omit it.
    public let originalContent: String?
    /// Post-edit snapshot captured after this thread's most recent edit ("after"
    /// side of the snapshot-pair diff). When both `originalContent` and
    /// `modifiedContent` are present, mobile renders the diff directly from
    /// them and ignores `fullFileDiff` / `hunks`.
    public let modifiedContent: String?

    public init(
        path: String,
        name: String,
        containsWrite: Bool,
        hunks: [SyncEditHunk],
        fullFileDiff: String? = nil,
        originalContent: String? = nil,
        modifiedContent: String? = nil
    ) {
        self.path = path
        self.name = name
        self.containsWrite = containsWrite
        self.hunks = hunks
        self.fullFileDiff = fullFileDiff
        self.originalContent = originalContent
        self.modifiedContent = modifiedContent
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, containsWrite, hunks, fullFileDiff, originalContent, modifiedContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.name = try c.decode(String.self, forKey: .name)
        self.containsWrite = try c.decode(Bool.self, forKey: .containsWrite)
        self.hunks = try c.decode([SyncEditHunk].self, forKey: .hunks)
        self.fullFileDiff = try c.decodeIfPresent(String.self, forKey: .fullFileDiff)
        self.originalContent = try c.decodeIfPresent(String.self, forKey: .originalContent)
        self.modifiedContent = try c.decodeIfPresent(String.self, forKey: .modifiedContent)
    }
}

/// Which side of the working tree a git change lives on.
public enum SyncGitChangeKind: String, Codable, Sendable {
    case staged
    case unstaged
    case untracked
}

/// One uncommitted file in the project's working tree, with its unified diff.
public struct SyncGitChange: Codable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(displayPath)" }
    /// Path relative to the repository root.
    public let displayPath: String
    /// Porcelain status letter (M/A/D/R/?/…).
    public let statusChar: String
    public let kind: SyncGitChangeKind
    /// Unified diff text. For untracked files this is an all-added diff.
    public let unifiedDiff: String
    /// True when `unifiedDiff` was clipped because it exceeded the line cap.
    public let truncated: Bool

    public init(
        displayPath: String,
        statusChar: String,
        kind: SyncGitChangeKind,
        unifiedDiff: String,
        truncated: Bool
    ) {
        self.displayPath = displayPath
        self.statusChar = statusChar
        self.kind = kind
        self.unifiedDiff = unifiedDiff
        self.truncated = truncated
    }
}

/// Desktop reply to a `ThreadChangesRequestPayload`: the two datasets backing
/// the mobile "View Changes" sheet.
public struct ThreadChangesResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let sessionID: String
    /// False when the request could not be served (e.g. not a git repository).
    public let ok: Bool
    public let errorMessage: String?
    /// Every file edited in the thread session.
    public let turnEdits: [SyncFileEdit]
    /// Uncommitted git changes in the session's project.
    public let uncommitted: [SyncGitChange]

    public init(
        clientRequestID: UUID,
        sessionID: String,
        ok: Bool,
        errorMessage: String? = nil,
        turnEdits: [SyncFileEdit],
        uncommitted: [SyncGitChange]
    ) {
        self.clientRequestID = clientRequestID
        self.sessionID = sessionID
        self.ok = ok
        self.errorMessage = errorMessage
        self.turnEdits = turnEdits
        self.uncommitted = uncommitted
    }
}
