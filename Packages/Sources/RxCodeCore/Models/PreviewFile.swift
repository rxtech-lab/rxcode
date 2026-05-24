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
    /// When non-nil, `FileDiffView` diffs this snapshot against the current
    /// on-disk content and ignores `editHunks` — yielding an exact diff even
    /// when other agents have concurrently modified the file.
    public let originalContent: String?

    public init(
        path: String,
        name: String,
        editHunks: [EditHunk] = [],
        gitDiffMode: GitDiffMode? = nil,
        showFullFileDiff: Bool = false,
        originalContent: String? = nil
    ) {
        self.path = path
        self.name = name
        self.editHunks = editHunks
        self.gitDiffMode = gitDiffMode
        self.showFullFileDiff = showFullFileDiff
        self.originalContent = originalContent
    }
}
