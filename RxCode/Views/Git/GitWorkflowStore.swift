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

enum GitPushSource {
    case branch(GitLocalBranch)
    case tag(GitTag)
}

struct GitAmendDraft {
    let commit: GitCommit
    let branch: String?
    let message: String
    let changes: GitChangedFiles<GitCommitFile>
    var files: [GitCommitFile] { changes.files }

    static func load(head: String, branch: String?, at root: String) async -> Self? {
        async let originalMessage = GitRepositoryLoader.commitMessage(for: head, at: root)
        guard let commit = await GitRepositoryLoader.history(at: root, ref: head, limit: 1).first,
              !Task.isCancelled else { return nil }
        let changes = await GitChangedFiles.load(in: commit, at: root)
        guard let message = await originalMessage else { return nil }
        return Self(commit: commit, branch: branch, message: message, changes: changes)
    }
}

/// Flows presented in their own sheets.
enum GitSheet: Identifiable {
    case commit(amend: GitAmendDraft? = nil)
    case pull
    case push(GitPushSource)
    case createBranch(startPoint: String, label: String)
    case renameBranch(String)
    case deleteBranch(GitLocalBranch)
    case createTag(GitCommit)
    case reword(GitCommit)
    case interactiveRebase(base: GitCommit, steps: [GitRebaseStep])
    case stash
    case editGitIgnore(patterns: [String])
    case addRemote
    case searchTags
    case createPullRequest(GitPullRequestTarget)

    var id: String {
        switch self {
        case .commit(let amend): amend == nil ? "commit" : "amend"
        case .pull: "pull"
        case .push(.branch(let branch)): "push-branch-\(branch.name)"
        case .push(.tag(let tag)): "push-tag-\(tag.name)"
        case .createBranch(let start, _): "branch-\(start)"
        case .renameBranch(let name): "rename-\(name)"
        case .deleteBranch(let branch): "delete-branch-\(branch.name)"
        case .createTag(let commit): "tag-\(commit.id)"
        case .reword(let commit): "reword-\(commit.id)"
        case .interactiveRebase(let base, _): "rebase-\(base.id)"
        case .stash: "stash"
        case .editGitIgnore: "gitignore"
        case .addRemote: "remote"
        case .searchTags: "search-tags"
        case .createPullRequest(let target): "pull-request-\(target.repository)-\(target.branch)"
        }
    }
}

/// Destructive actions that need explicit confirmation.
enum GitConfirmation: Identifiable {
    case reset(GitCommit, GitWorkflow.ResetMode)
    case deleteRemoteBranch(GitRemoteBranch)
    case deleteTag(String)
    case dropStash(GitStash)
    case discard([GitChangeFile])
    case removeRemote(String)

    var id: String {
        switch self {
        case .reset(let commit, let mode): "reset-\(mode.rawValue)-\(commit.id)"
        case .deleteRemoteBranch(let branch): "delete-remote-\(branch.id)"
        case .deleteTag(let name): "delete-tag-\(name)"
        case .dropStash(let stash): "drop-\(stash.id)"
        case .discard(let files): "discard-\(files.map(\.id).joined(separator: ","))"
        case .removeRemote(let name): "remove-remote-\(name)"
        }
    }
}

struct GitHubCheckout: Equatable {
    let repository: String
    let branch: String?
    /// Remote the GitHub repository was resolved from (e.g. `origin`).
    var remote: String = "origin"
    /// Branch `remote/HEAD` points at, used as the PR base.
    var defaultBranch: String?
}

/// A pushed branch that has no pull request yet.
struct GitPullRequestTarget: Equatable, Hashable {
    /// `owner/repo` on GitHub.
    let repository: String
    /// Branch name on the remote (the PR head).
    let branch: String
    /// Branch the PR merges into; nil lets the server use the repo default.
    let base: String?
    let remote: String
}

/// Repository state for one Git workflow window: refs, the commit graph, and
/// the operation currently running.
@MainActor @Observable
final class GitWorkflowStore {
    static let pageSize = 400

    let root: String
    private(set) var snapshot = GitRepositorySnapshot()
    private(set) var gitHubCheckout: GitHubCheckout?
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
    /// PR status for ``gitHubCheckout``'s branch, set by the window's lookup.
    private(set) var pullRequestStatus: (checkout: GitHubCheckout, presence: BranchPullRequestPresence?)?
    @ObservationIgnored private var snapshotToken = UUID()
    @ObservationIgnored private var historyToken = UUID()
    @ObservationIgnored private var fetchTask: Task<String?, Never>?

    init(root: String) {
        self.root = root
    }

    var selectedCommit: GitCommit? {
        guard let selectedCommitID else { return nil }
        return commits.first { $0.id == selectedCommitID }
    }

    var currentBranch: GitLocalBranch? { snapshot.currentLocalBranch }

    /// PR status for the current checkout, or nil while unknown or stale.
    var pullRequestPresence: BranchPullRequestPresence? {
        guard let pullRequestStatus, pullRequestStatus.checkout == gitHubCheckout else { return nil }
        return pullRequestStatus.presence
    }

    func setPullRequestPresence(_ presence: BranchPullRequestPresence?, for checkout: GitHubCheckout) {
        pullRequestStatus = (checkout, presence)
    }

    /// The current branch when it has been pushed to GitHub but has no pull
    /// request yet — the cue for the toolbar and sidebar "Create PR" prompts.
    var pullRequestSuggestion: GitPullRequestTarget? {
        guard let checkout = gitHubCheckout, let branch = checkout.branch,
              let local = currentBranch, local.upstream != nil,
              pullRequestPresence == .missing,
              branch != checkout.defaultBranch else { return nil }
        return GitPullRequestTarget(
            repository: checkout.repository,
            branch: branch,
            base: checkout.defaultBranch,
            remote: checkout.remote
        )
    }

    var defaultRemote: String? {
        snapshot.remotes.contains("origin") ? "origin" : snapshot.remotes.first
    }

    func checkout(_ item: GitSidebarItem) {
        switch item {
        case .branch(let name):
            guard snapshot.localBranches.contains(where: { $0.name == name && !$0.isCurrent }) else { return }
            perform("Switching branch…") { await GitWorkflow.checkout(name, at: self.root) }
        case .remoteBranch(let ref):
            guard let remote = snapshot.remoteBranches.first(where: { $0.refName == ref }) else { return }
            perform("Switching branch…") {
                await GitWorkflow.checkout(remote: remote, localBranches: self.snapshot.localBranches, at: self.root)
            }
        default:
            break
        }
    }

    func isOnCurrentBranch(_ commit: GitCommit) -> Bool {
        headAncestors.contains(commit.id)
    }

    func fetchRemotes(inBackground: Bool = false) async -> String? {
        if let fetchTask { return await fetchTask.value }
        let task = Task { [root] in await GitWorkflow.fetch(at: root, inBackground: inBackground) }
        fetchTask = task
        defer { fetchTask = nil }
        return await task.value
    }

    func fetchRemotesPeriodically(every interval: Duration = .seconds(60)) async {
        guard !snapshot.remotes.isEmpty else { return }
        while !Task.isCancelled {
            if operation == nil, sheet == nil, confirmation == nil {
                let previous = snapshot
                _ = await fetchRemotes(inBackground: true)
                guard !Task.isCancelled else { return }
                // A multi-remote fetch can update some refs even when another remote fails.
                await reloadSnapshot()
                if snapshot.remoteBranches != previous.remoteBranches || snapshot.tags != previous.tags {
                    await reloadHistory()
                }
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
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
        let newGitHubCheckout = await loadGitHubCheckout(in: newSnapshot)
        guard token == snapshotToken, !Task.isCancelled else { return }
        if snapshot != newSnapshot {
            snapshot = newSnapshot
            headAncestors = ancestors(of: newSnapshot.headCommit, in: commits)
            switch selection {
            case .branch(let name) where !newSnapshot.localBranches.contains(where: { $0.name == name }),
                 .remoteBranch(let name) where !newSnapshot.remoteBranches.contains(where: { $0.refName == name }):
                selection = .allCommits
            default:
                break
            }
        }
        if gitHubCheckout != newGitHubCheckout { gitHubCheckout = newGitHubCheckout }
    }

    private func loadGitHubCheckout(in snapshot: GitRepositorySnapshot) async -> GitHubCheckout? {
        let branch = snapshot.currentLocalBranch
        let preferredRemotes = [branch?.upstreamRemote, "origin"].compactMap { $0 }
        var checked = Set<String>()
        for remote in preferredRemotes + snapshot.remotes
        where snapshot.remotes.contains(remote) && checked.insert(remote).inserted {
            guard !Task.isCancelled else { return nil }
            guard let url = await GitHelper.run(["remote", "get-url", "--", remote], at: root),
                  let repository = parseGitHubOwnerRepo(from: url) else { continue }
            let defaultBranch = await AppState.remoteDefaultBranch(remote: remote, at: root)
            let branchPrefix = "refs/heads/"
            if branch?.upstreamRemote == remote, let upstreamRef = branch?.upstreamRef, upstreamRef.hasPrefix(branchPrefix) {
                return GitHubCheckout(
                    repository: repository,
                    branch: String(upstreamRef.dropFirst(branchPrefix.count)),
                    remote: remote,
                    defaultBranch: defaultBranch
                )
            }
            return GitHubCheckout(
                repository: repository,
                branch: branch?.name ?? snapshot.currentBranch,
                remote: remote,
                defaultBranch: defaultBranch
            )
        }
        return nil
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingHistory else { return }
        limit += Self.pageSize
        await reloadHistory()
    }

    func reloadHistory() async {
        let token = UUID()
        historyToken = token
        guard selection.showsHistory else {
            isLoadingHistory = false
            return
        }
        isLoadingHistory = true
        defer { if token == historyToken { isLoadingHistory = false } }
        let newCommits = await GitRepositoryLoader.history(at: root, ref: selection.historyRef, limit: limit)
        guard token == historyToken, !Task.isCancelled else { return }
        apply(newCommits)
    }

    private func apply(_ newCommits: [GitCommit]) {
        canLoadMore = newCommits.count >= limit
        if !newCommits.contains(where: { $0.id == selectedCommitID }) {
            selectedCommitID = newCommits.first?.id
        }
        guard newCommits != commits else { return }
        commits = newCommits
        rows = GitGraphLayout.layout(newCommits)
        graphWidth = max(1, rows.map(\.width).max() ?? 1)
        headAncestors = ancestors(of: snapshot.headCommit, in: newCommits)
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
