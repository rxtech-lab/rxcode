import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Opens the full Git workflow window for a checkout.
struct GitWindowValue: Codable, Hashable {
    let path: String
    var workspaceID: String?
}

struct GitWindowRoot: View {
    let workspaceManager: WorkspaceManager
    let workspaceID: String
    let path: String
    @State private var windowState = WindowState()
    @State private var repository = RepositoryStatus()
    @State private var root: String?
    @State private var resolved = false

    private var appState: AppState { workspaceManager.appState(for: workspaceID) }

    var body: some View {
        Group {
            if let root {
                GitWorkflowView(root: root)
                    .environment(repository)
                    .task(id: root) { await repository.observe(root) }
            } else if resolved {
                ContentUnavailableView("No Git repository", systemImage: "arrow.triangle.branch",
                                       description: Text(path))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(appState)
        .environment(windowState)
        .frame(minWidth: 900, minHeight: 560)
        .task(id: path) {
            let top = await GitHelper.run(["rev-parse", "--show-toplevel"], at: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            root = top?.isEmpty == false ? top : nil
            resolved = true
        }
    }
}

struct GitWorkflowView: View {
    @State private var store: GitWorkflowStore
    @State private var selectedChange: GitChangeFile?
    @Environment(RepositoryStatus.self) private var repository

    init(root: String) {
        _store = State(initialValue: GitWorkflowStore(root: root))
    }

    var body: some View {
        NavigationSplitView {
            GitWorkflowSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            detail
        }
        .navigationTitle((store.root as NSString).lastPathComponent)
        .navigationSubtitle(store.snapshot.currentBranch ?? store.snapshot.headCommit.map { String(localized: "Detached at \(String($0.prefix(7)))") } ?? "")
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let pending = store.snapshot.pendingOperation {
                GitPendingOperationBanner(operation: pending, store: store)
            }
        }
        .disabled(store.operation != nil)
        .overlay { GitOperationOverlay(operation: store.operation) }
        .task(id: store.selection) { await store.reloadHistory() }
        .onChange(of: repository.state) { Task { await store.reload() } }
        .task { await store.reload() }
        .sheet(item: $store.sheet) { sheet in sheetContent(sheet) }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }),
            titleVisibility: .visible,
            presenting: store.confirmation
        ) { confirmation in
            Button(confirmationButton(confirmation), role: .destructive) { confirm(confirmation) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .alert("Git operation failed", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    // MARK: Columns

    @ViewBuilder private var content: some View {
        switch store.selection {
        case .localChanges:
            GitLocalChangesView(store: store, selectedChange: $selectedChange)
        case .stash(let selector):
            if let stash = store.snapshot.stashes.first(where: { $0.selector == selector }) {
                GitStashSummaryView(stash: stash, store: store)
            } else {
                ContentUnavailableView("Stash not found", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            GitHistoryGraphView(store: store)
        }
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
        case .localChanges:
            GitLocalChangeDiffView(file: selectedChange)
        case .stash(let selector):
            if let stash = store.snapshot.stashes.first(where: { $0.selector == selector }) {
                GitStashDiffView(stash: stash, root: store.root)
            } else {
                Color.clear
            }
        default:
            if let commit = store.selectedCommit {
                GitCommitDetailView(commit: commit, store: store)
                    .id(commit.id)
            } else {
                ContentUnavailableView("Select a commit", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Right-click a commit to reword, rebase, cherry-pick, or reset."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                store.perform("Fetching…") { await GitWorkflow.fetch(at: store.root) }
            }
            .help("Fetch all remotes")
            .disabled(store.snapshot.remotes.isEmpty)

            Menu {
                Button("Pull (Fast-forward Only)") { pull(.fastForwardOnly) }
                Button("Pull (Merge)") { pull(.merge) }
                Button("Pull (Rebase)") { pull(.rebase) }
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            } primaryAction: {
                pull(.fastForwardOnly)
            }
            .help(pullHelp)
            .disabled(store.currentBranch?.upstream == nil)

            Menu {
                Button("Push") { push(force: false) }
                Button("Force Push (with Lease)…") {
                    if let branch = store.currentBranch { store.confirmation = .forcePush(branch) }
                }
                .disabled(store.currentBranch?.upstream == nil)
            } label: {
                Label("Push", systemImage: "arrow.up.circle")
            } primaryAction: {
                push(force: false)
            }
            .help(pushHelp)
            .disabled(store.currentBranch == nil || (store.currentBranch?.upstream == nil && store.defaultRemote == nil))

            Button("Stash", systemImage: "archivebox") { store.sheet = .stash }
                .help("Stash uncommitted changes")
            Button("New Branch", systemImage: "plus") {
                store.sheet = .createBranch(startPoint: "HEAD", label: store.snapshot.currentBranch ?? "HEAD")
            }
            .help("Create a branch from HEAD")
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task {
                    await repository.refresh(at: store.root)
                    await store.reload()
                }
            }
            .help("Reload the repository")
        }
    }

    private var pullHelp: String {
        guard let branch = store.currentBranch, let upstream = branch.upstream else {
            return String(localized: "The current branch has no upstream")
        }
        return branch.behind > 0 ? String(localized: "Pull \(branch.behind) commits from \(upstream)") : String(localized: "Pull from \(upstream)")
    }

    private var pushHelp: String {
        guard let branch = store.currentBranch else { return String(localized: "Check out a branch to push") }
        guard let upstream = branch.upstream else { return String(localized: "Publish \(branch.name)") }
        return branch.ahead > 0 ? String(localized: "Push \(branch.ahead) commits to \(upstream)") : String(localized: "Push to \(upstream)")
    }

    private func pull(_ strategy: GitWorkflow.PullStrategy) {
        store.perform("Pulling…") { await GitWorkflow.pull(strategy, at: store.root) }
    }

    private func push(force: Bool) {
        guard let branch = store.currentBranch else { return }
        let remote = store.defaultRemote
        store.perform(force ? "Force pushing…" : "Pushing…") {
            await GitWorkflow.push(branch: branch, remote: remote, force: force, at: store.root)
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheetContent(_ sheet: GitSheet) -> some View {
        switch sheet {
        case .commit:
            if case .ready(let tree) = repository.state {
                GitWindowCommitSheet(tree: tree, store: store)
            }
        case .createBranch(let start, let label):
            GitCreateBranchSheet(store: store, startPoint: start, label: label)
        case .renameBranch(let name):
            GitRenameBranchSheet(store: store, branch: name)
        case .createTag(let commit):
            GitCreateTagSheet(store: store, commit: commit)
        case .reword(let commit):
            GitRewordSheet(store: store, commit: commit)
        case .interactiveRebase(let base, let steps):
            GitInteractiveRebaseSheet(store: store, base: base, steps: steps)
        case .stash:
            GitStashSheet(store: store)
        case .addRemote:
            GitAddRemoteSheet(store: store)
        }
    }

    // MARK: Confirmations

    private var confirmationTitle: String {
        guard let confirmation = store.confirmation else { return "" }
        switch confirmation {
        case .reset(_, let mode):
            return String(localized: "Reset \(store.snapshot.currentBranch ?? "HEAD") (\(mode.rawValue))?")
        case .deleteBranch(let name): return String(localized: "Delete branch “\(name)”?")
        case .deleteRemoteBranch(let branch): return String(localized: "Delete “\(branch.refName)” from the remote?")
        case .deleteTag(let name): return String(localized: "Delete tag “\(name)”?")
        case .dropStash(let stash): return String(localized: "Drop \(stash.selector)?")
        case .forcePush(let branch): return String(localized: "Force push “\(branch.name)”?")
        case .discard(let files): return String(localized: "Discard changes in \(files.count) files?")
        case .removeRemote(let name): return String(localized: "Remove remote “\(name)”?")
        }
    }

    private func confirmationButton(_ confirmation: GitConfirmation) -> String {
        switch confirmation {
        case .reset: String(localized: "Reset")
        case .deleteBranch, .deleteRemoteBranch, .deleteTag: String(localized: "Delete")
        case .dropStash: String(localized: "Drop")
        case .forcePush: String(localized: "Force Push")
        case .discard: String(localized: "Discard")
        case .removeRemote: String(localized: "Remove")
        }
    }

    private func confirmationMessage(_ confirmation: GitConfirmation) -> String {
        switch confirmation {
        case .reset(let commit, let mode):
            let target = "\(commit.shortID) \(commit.subject)"
            return switch mode {
            case .soft: String(localized: "Moves the branch to \(target). Later commits’ changes stay staged.")
            case .mixed: String(localized: "Moves the branch to \(target). Later commits’ changes stay in the working tree, unstaged.")
            case .hard: String(localized: "Moves the branch to \(target) and permanently discards later commits and all uncommitted changes.")
            }
        case .deleteBranch: return String(localized: "Unmerged commits on this branch are deleted too.")
        case .deleteRemoteBranch: return String(localized: "Removes the branch for everyone using this remote.")
        case .deleteTag: return String(localized: "Only the local tag is deleted.")
        case .dropStash(let stash): return stash.message
        case .forcePush: return String(localized: "Overwrites the remote branch. The push fails if someone else pushed in the meantime.")
        case .discard(let files): return files.prefix(8).map(\.displayPath).joined(separator: "\n") + String(localized: "\nThis can’t be undone.")
        case .removeRemote: return String(localized: "Remote-tracking branches for this remote are removed.")
        }
    }

    private func confirm(_ confirmation: GitConfirmation) {
        let root = store.root
        switch confirmation {
        case .reset(let commit, let mode):
            store.perform("Resetting…") { await GitWorkflow.reset(to: commit.id, mode: mode, at: root) }
        case .deleteBranch(let name):
            store.perform("Deleting branch…") { await GitWorkflow.deleteBranch(name, force: true, at: root) }
            if store.selection == .branch(name) { store.selection = .allCommits }
        case .deleteRemoteBranch(let branch):
            store.perform("Deleting remote branch…") { await GitWorkflow.deleteRemoteBranch(branch, at: root) }
            if store.selection == .remoteBranch(branch.refName) { store.selection = .allCommits }
        case .deleteTag(let name):
            store.perform("Deleting tag…") { await GitWorkflow.deleteTag(name, at: root) }
            if store.selection == .tag(name) { store.selection = .allCommits }
        case .dropStash(let stash):
            store.perform("Dropping stash…") { await GitWorkflow.dropStash(stash, at: root) }
            if store.selection == .stash(stash.selector) { store.selection = .allCommits }
        case .forcePush(let branch):
            let remote = store.defaultRemote
            store.perform("Force pushing…") { await GitWorkflow.push(branch: branch, remote: remote, force: true, at: root) }
        case .discard(let files):
            let untracked = files.filter { $0.diffMode == .untracked }.flatMap(\.pathspecs)
            let tracked = files.filter { $0.diffMode == .unstaged }.flatMap(\.pathspecs)
            store.perform("Discarding changes…") {
                if let failure = await GitWorkflow.discard(paths: tracked, untracked: false, at: root) { return failure }
                return await GitWorkflow.discard(paths: untracked, untracked: true, at: root)
            }
        case .removeRemote(let name):
            store.perform("Removing remote…") { await GitWorkflow.removeRemote(name, at: root) }
        }
    }
}

/// Wraps the shared commit sheet so the window reloads its graph afterwards.
private struct GitWindowCommitSheet: View {
    let tree: GitWorkingTree
    let store: GitWorkflowStore
    @State private var message = ""

    var body: some View {
        GitCommitSheet(tree: tree, message: $message)
            .onDisappear { Task { await store.reload() } }
    }
}

// MARK: - Pending operation banner

private struct GitPendingOperationBanner: View {
    let operation: GitPendingOperation
    let store: GitWorkflowStore

    private var title: LocalizedStringResource {
        switch operation {
        case .rebase: "Rebase in progress"
        case .merge: "Merge in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ClaudeTheme.statusWarning)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                Text("Resolve conflicts and stage the files in Local Changes, then continue.")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            Spacer()
            Button("Local Changes") { store.selection = .localChanges }
            if operation.supportsSkip {
                Button("Skip") { resolve(.skip, "Skipping…") }
            }
            Button("Abort") { resolve(.abort, "Aborting…") }
            Button("Continue") { resolve(.continue, "Continuing…") }
                .buttonStyle(.borderedProminent)
                .tint(ClaudeTheme.accent)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClaudeTheme.statusWarning.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func resolve(_ action: GitWorkflow.Continuation, _ label: LocalizedStringResource) {
        store.perform(label) { await GitWorkflow.resolve(operation, action, at: store.root) }
    }
}

// MARK: - Stash views

private struct GitStashSummaryView: View {
    let stash: GitStash
    let store: GitWorkflowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(stash.selector, systemImage: "archivebox")
                .font(.headline.monospaced())
            Text(stash.message)
                .textSelection(.enabled)
            Text(stash.tip).font(.caption.monospaced()).foregroundStyle(ClaudeTheme.textTertiary).textSelection(.enabled)
            HStack {
                Button("Apply") {
                    store.perform("Applying stash…") { await GitWorkflow.applyStash(stash, pop: false, at: store.root) }
                }
                Button("Pop") {
                    store.perform("Popping stash…") { await GitWorkflow.applyStash(stash, pop: true, at: store.root) }
                }
                Spacer()
                Button("Drop…", role: .destructive) { store.confirmation = .dropStash(stash) }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GitStashDiffView: View {
    let stash: GitStash
    let root: String
    @State private var lines: [DiffLine] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else if lines.isEmpty {
                ContentUnavailableView("No textual changes", systemImage: "doc.text.magnifyingglass")
            } else {
                DiffView(lines: lines, display: .scroll)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: stash.tip) {
            loading = true
            lines = DiffComputation.parseUnifiedDiff(await GitRepositoryLoader.stashDiff(stash, at: root))
            loading = false
        }
    }
}
