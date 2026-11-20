import Foundation
import RxCodeCore

/// What the Git window's sidebar points the content column at.
enum GitSidebarItem: Hashable {
    case localChanges
    case allCommits
    case branch(String)
    case remoteBranch(String)
    case tag(String)
    case stash(String)

    /// Ref whose history the content column shows, or nil for every ref.
    var historyRef: String? {
        switch self {
        case .branch(let name): "refs/heads/\(name)"
        case .remoteBranch(let name): "refs/remotes/\(name)"
        case .tag(let name): "refs/tags/\(name)"
        case .allCommits, .localChanges, .stash: nil
        }
    }

    var showsHistory: Bool {
        switch self {
        case .localChanges, .stash: false
        default: true
        }
    }
}

/// Create, update, and history-editing flows, each in its own sheet.
enum GitSheet: Identifiable {
    case commit
    case createBranch(startPoint: String, label: String)
    case renameBranch(String)
    case createTag(GitCommit)
    case reword(GitCommit)
    case interactiveRebase(base: GitCommit, steps: [GitRebaseStep])
    case stash
    case addRemote

    var id: String {
        switch self {
        case .commit: "commit"
        case .createBranch(let start, _): "branch-\(start)"
        case .renameBranch(let name): "rename-\(name)"
        case .createTag(let commit): "tag-\(commit.id)"
        case .reword(let commit): "reword-\(commit.id)"
        case .interactiveRebase(let base, _): "rebase-\(base.id)"
        case .stash: "stash"
        case .addRemote: "remote"
        }
    }
}

/// Destructive actions that need explicit confirmation.
enum GitConfirmation: Identifiable {
    case reset(GitCommit, GitWorkflow.ResetMode)
    case deleteBranch(String)
    case deleteRemoteBranch(GitRemoteBranch)
    case deleteTag(String)
    case dropStash(GitStash)
    case forcePush(GitLocalBranch)
    case discard([GitChangeFile])
    case removeRemote(String)

    var id: String {
        switch self {
        case .reset(let commit, let mode): "reset-\(mode.rawValue)-\(commit.id)"
        case .deleteBranch(let name): "delete-\(name)"
        case .deleteRemoteBranch(let branch): "delete-remote-\(branch.id)"
        case .deleteTag(let name): "delete-tag-\(name)"
        case .dropStash(let stash): "drop-\(stash.id)"
        case .forcePush(let branch): "force-\(branch.name)"
        case .discard(let files): "discard-\(files.map(\.id).joined(separator: ","))"
        case .removeRemote(let name): "remove-remote-\(name)"
        }
    }
}

/// Repository state for one Git workflow window: refs, the commit graph, and
/// the operation currently running.
@MainActor @Observable
final class GitWorkflowStore {
    static let pageSize = 400

    let root: String
    private(set) var snapshot = GitRepositorySnapshot()
    private(set) var commits: [GitCommit] = []
    private(set) var rows: [GitGraphRow] = []
    private(set) var graphWidth = 1
    private(set) var isLoadingHistory = false
    private(set) var canLoadMore = false
    /// Commits on the current branch within the loaded history, used to decide
    /// which history-editing actions apply.
    private(set) var headAncestors: Set<String> = []
    private(set) var limit = GitWorkflowStore.pageSize
    var selection: GitSidebarItem = .allCommits {
        didSet { if oldValue != selection { selectedCommitID = nil; limit = Self.pageSize } }
    }
    var selectedCommitID: String?
    var operation: LocalizedStringResource?
    var error: String?
    var sheet: GitSheet?
    var confirmation: GitConfirmation?
    @ObservationIgnored private var snapshotToken = UUID()
    @ObservationIgnored private var historyToken = UUID()

    init(root: String) {
        self.root = root
    }

    var selectedCommit: GitCommit? {
        guard let selectedCommitID else { return nil }
        return commits.first { $0.id == selectedCommitID }
    }

    var currentBranch: GitLocalBranch? { snapshot.currentLocalBranch }

    var defaultRemote: String? {
        snapshot.remotes.contains("origin") ? "origin" : snapshot.remotes.first
    }

    func isOnCurrentBranch(_ commit: GitCommit) -> Bool {
        headAncestors.contains(commit.id)
    }

    func reload() async {
        async let refs: Void = reloadSnapshot()
        async let history: Void = reloadHistory()
        _ = await (refs, history)
    }

    private func reloadSnapshot() async {
        let token = UUID()
        snapshotToken = token
        let newSnapshot = await GitRepositoryLoader.snapshot(at: root)
        guard token == snapshotToken, !Task.isCancelled else { return }
        if snapshot != newSnapshot {
            snapshot = newSnapshot
            headAncestors = ancestors(of: newSnapshot.headCommit, in: commits)
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingHistory else { return }
        limit += Self.pageSize
        await reloadHistory()
    }

    func reloadHistory() async {
        let token = UUID()
        historyToken = token
        let newCommits = await loadHistory()
        guard token == historyToken, !Task.isCancelled else { return }
        apply(newCommits)
    }

    private func loadHistory() async -> [GitCommit] {
        guard selection.showsHistory else { return commits }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        return await GitRepositoryLoader.history(at: root, ref: selection.historyRef, limit: limit)
    }

    private func apply(_ newCommits: [GitCommit]) {
        canLoadMore = newCommits.count >= limit
        guard newCommits != commits else { return }
        commits = newCommits
        rows = GitGraphLayout.layout(newCommits)
        graphWidth = max(1, rows.map(\.width).max() ?? 1)
        headAncestors = ancestors(of: snapshot.headCommit, in: newCommits)
        if let selectedCommitID, !newCommits.contains(where: { $0.id == selectedCommitID }) {
            self.selectedCommitID = nil
        }
    }

    private func ancestors(of head: String?, in commits: [GitCommit]) -> Set<String> {
        guard let head else { return [] }
        let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<String> = []
        var stack = [head]
        while let id = stack.popLast() {
            guard !visited.contains(id), let commit = byID[id] else { continue }
            visited.insert(id)
            stack.append(contentsOf: commit.parents)
        }
        return visited
    }

    /// Loads the commits from `commit` through HEAD and opens the interactive rebase sheet.
    func beginInteractiveRebase(from commit: GitCommit) {
        guard operation == nil else { return }
        operation = "Preparing rebase…"
        Task {
            let steps = await GitWorkflow.rebaseSteps(from: commit, at: root)
            operation = nil
            if let steps {
                sheet = .interactiveRebase(base: commit, steps: steps)
            } else {
                error = String(localized: "Interactive rebase needs a commit on the current branch with no merge commits after it.")
            }
        }
    }

    /// Runs a mutating git command behind the window's progress overlay, then
    /// reloads. Failures surface in the window's alert.
    func perform(_ label: LocalizedStringResource, action: @escaping () async -> String?) {
        guard operation == nil else { return }
        operation = label
        Task {
            let failure = await action()
            await reload()
            operation = nil
            error = failure
        }
    }
}
