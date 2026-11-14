import Foundation

public struct PreviewFile: Identifiable, Sendable {
    public struct EditHunk: Sendable, Equatable {
        public let oldString: String
        public let newString: String

        public init(oldString: String, newString: String) {
            self.oldString = oldString
            self.newString = newString
        }
    }

    /// How `FileDiffView` should fetch the diff when `editHunks` is empty.
    public enum GitDiffMode: Sendable, Equatable {
        /// `git diff -- file` (worktree vs index)
        case unstaged
        /// `git diff --cached -- file` (index vs HEAD)
        case staged
        /// Untracked file — diff entire file against /dev/null
        case untracked
    }

    public let id = UUID()
    public let path: String
    public let name: String
    public let editHunks: [EditHunk]
    public let gitDiffMode: GitDiffMode?
    public let showFullFileDiff: Bool
    /// File contents captured before this thread's first edit to the path.
    /// Fixed once set; together with `modifiedContent` forms the snapshot pair
    /// that `FileDiffView` diffs to render this thread's changes.
    public let originalContent: String?
    /// File contents captured immediately after the thread's most recent edit
    /// tool_result. When both `originalContent` and `modifiedContent` are
    /// present `FileDiffView` diffs them directly and ignores `editHunks` and
    /// the current on-disk content — giving an exact, thread-isolated diff
    /// even when other agents concurrently modify the file.
    public let modifiedContent: String?
    /// When true, another thread edited this file between two turns of the
    /// current thread, so `FileDiffView` reverse-applies `editHunks` onto
    /// `modifiedContent` instead of diffing `originalContent -> modifiedContent`
    /// verbatim (which would also highlight the other thread's lines).
    public let preferHunks: Bool

    public init(
        path: String,
        name: String,
        editHunks: [EditHunk] = [],
        gitDiffMode: GitDiffMode? = nil,
        showFullFileDiff: Bool = false,
        originalContent: String? = nil,
        modifiedContent: String? = nil,
        preferHunks: Bool = false
    ) {
        self.path = path
        self.name = name
        self.editHunks = editHunks
        self.gitDiffMode = gitDiffMode
        self.showFullFileDiff = showFullFileDiff
        self.originalContent = originalContent
        self.modifiedContent = modifiedContent
        self.preferHunks = preferHunks
    }
}
