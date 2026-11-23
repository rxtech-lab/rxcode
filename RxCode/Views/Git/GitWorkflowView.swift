import RxAuthSwift
import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Opens the full Git workflow window for a checkout.
struct GitWindowValue: Codable, Hashable {
    let path: String
    var workspaceID: String?
    var projectID: UUID?
}

struct GitWindowRoot: View {
    let workspaceManager: WorkspaceManager
    @Binding var value: GitWindowValue
    @State private var openingCheckout: GitWindowValue
    @State private var windowState = WindowState()

    init(workspaceManager: WorkspaceManager, value: Binding<GitWindowValue>) {
        self.workspaceManager = workspaceManager
        _value = value
        _openingCheckout = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        let workspaceID = value.workspaceID ?? workspaceManager.frontmostWorkspaceID
        let projectPicker = GitProjectPicker(checkout: $value, openingCheckout: openingCheckout)
        GitCheckoutView(path: value.path, projectPicker: projectPicker)
            .id(value.path)
            .environment(workspaceManager.appState(for: workspaceID))
            .environment(windowState)
            .frame(minWidth: 900, minHeight: 560)
    }
}

private struct GitCheckoutView: View {
    let path: String
    let projectPicker: GitProjectPicker
    @State private var root: String?
    @State private var resolved = false

    var body: some View {
        Group {
            if let root {
                GitWorkflowView(root: root, projectPicker: projectPicker)
            } else {
                Group {
                    if resolved {
                        ContentUnavailableView("No Git repository", systemImage: "arrow.triangle.branch",
                                               description: Text(path))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
                .toolbar(removing: .title)
                .toolbar { projectPicker }
            }
        }
        .task {
            let top = await RepositoryState.gitPath(["--show-toplevel"], at: path)
            guard !Task.isCancelled else { return }
            root = top
            resolved = true
        }
    }
}

private struct GitProjectPicker: ToolbarContent {
    @Binding var checkout: GitWindowValue
    let openingCheckout: GitWindowValue
    var branch = ""
    @Environment(AppState.self) private var appState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            picker
                .toolbarTitleWidth()
        }
        if !branch.isEmpty {
            ToolbarItem(placement: .navigation) {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .toolbarTitleWidth()
                    .padding(.horizontal, 4)
                    .help(branch)
                    .accessibilityIdentifier("git-current-branch")
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var picker: some View {
        let projects = appState.projects.filter { !$0.isGlobalChat && !$0.path.isEmpty }
        let workspaceID = appState.activeWorkspace.id
        let original = GitWindowValue(path: openingCheckout.path, workspaceID: workspaceID, projectID: openingCheckout.projectID)
        let current = GitWindowValue(path: checkout.path, workspaceID: workspaceID, projectID: checkout.projectID)
        var options = projects.map { GitWindowValue(path: $0.path, workspaceID: workspaceID, projectID: $0.id) }
        let selected = options.first {
            $0.path == current.path && (current.projectID == nil || $0.projectID == current.projectID)
        } ?? current
        if !options.contains(where: { $0.path == original.path }) {
            options.append(original)
        }
        if !options.contains(selected) {
            options.append(selected)
        }

        let selectedTitle = title(for: selected, projects: projects)
        return Menu {
            Picker("Project", selection: Binding(get: { selected }, set: { checkout = $0 })) {
                ForEach(options, id: \.self) { option in
                    Text(title(for: option, projects: projects)).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selectedTitle)
                .truncationMode(.middle)
        }
        .help(selectedTitle)
        .accessibilityLabel("Project")
        .accessibilityValue(selectedTitle)
        .accessibilityIdentifier("git-project-picker")
    }

    private func title(for checkout: GitWindowValue, projects: [Project]) -> String {
        guard let project = projects.first(where: { $0.id == checkout.projectID && $0.path == checkout.path }) else {
            return URL(fileURLWithPath: checkout.path).lastPathComponent
        }
        guard projects.contains(where: { $0.id != project.id && $0.name == project.name }) else {
            return project.name
        }
        return "\(project.name) (\((project.path as NSString).abbreviatingWithTildeInPath))"
    }
}

private struct GitWorkflowView: View {
    private struct PullRequestLookup: Equatable {
        let checkout: GitHubCheckout
        let accountID: String
        let refreshCount: Int
    }

    @State private var store: GitWorkflowStore
    @State private var commitTab: GitCommitDetailTab = .changes
    @State private var pullRequestRefreshCount = 0
    @State private var showsPullRequestTip = false
    @State private var repository = RepositoryStatus(includeFileTrees: true)
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    private let projectPicker: GitProjectPicker

    init(root: String, projectPicker: GitProjectPicker) {
        _store = State(initialValue: GitWorkflowStore(root: root))
        self.projectPicker = projectPicker
    }

    var body: some View {
        NavigationSplitView {
            GitWorkflowSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            // Attach the toolbar to the detail column (as the main window does) so the
            // flexible spacer pushes the action items to the trailing edge.
            workspacePane
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle((store.root as NSString).lastPathComponent)
        .toolbar(removing: .title)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let pending = store.snapshot.pendingOperation {
                GitPendingOperationBanner(operation: pending, store: store)
            }
        }
        .disabled(store.operation != nil)
        .overlay { GitOperationOverlay(operation: store.operation) }
        .task { await repository.observe(store.root) }
        .task(id: store.selection) { await store.reloadHistory() }
        .onChange(of: repository.state) { Task { await store.reload() } }
        .task { await store.reload() }
        .task(id: store.snapshot.remotes) { await store.fetchRemotesPeriodically() }
        .task(id: pullRequestLookup) {
            guard let lookup = pullRequestLookup, let branch = lookup.checkout.branch else {
                // Signed out or no branch: forget any earlier result so no stale prompt lingers.
                if let checkout = store.gitHubCheckout { store.setPullRequestPresence(nil, for: checkout) }
                return
            }
            let presence = await appState.lookUpBranchPullRequest(repository: lookup.checkout.repository, branch: branch)
            guard !Task.isCancelled, pullRequestLookup == lookup else { return }
            store.setPullRequestPresence(presence, for: lookup.checkout)
        }
        .onChange(of: store.pullRequestSuggestion, initial: true) { _, suggestion in
            showsPullRequestTip = suggestion.map { !GitPullRequestTipLedger.isDismissed($0) } ?? false
        }
        .sheet(item: $store.sheet) { sheet in sheetContent(sheet).appThemeForeground() }
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
        .environment(repository)
    }

    // MARK: Workspace

    @ViewBuilder private var workspacePane: some View {
        switch store.selection {
        case .localChanges:
            GitLocalChangesView(store: store)
        case .stash(let selector):
            if let stash = store.snapshot.stashes.first(where: { $0.selector == selector }) {
                HSplitView {
                    GitStashSummaryView(stash: stash, store: store)
                        .frame(minWidth: 240, idealWidth: 300, maxHeight: .infinity)
                    GitStashDiffView(stash: stash, root: store.root)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Stash not found", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            GeometryReader { geometry in
                let minimumCommitHeight: CGFloat = 200
                let measuredHeight = geometry.size.height
                // The split view can receive an unbounded or undersized height during measurement.
                let height = measuredHeight.isFinite ? max(minimumCommitHeight, measuredHeight) : minimumCommitHeight
                let historyHeight = min(300, height * 0.4, height - minimumCommitHeight)
                VSplitView {
                    GitHistoryGraphView(store: store)
                        .frame(minHeight: historyHeight, maxHeight: .infinity)
                    commitPane
                        .frame(minHeight: minimumCommitHeight, idealHeight: height - historyHeight, maxHeight: .infinity)
                        .layoutPriority(1)
                }
            }
        }
    }

    @ViewBuilder private var commitPane: some View {
        if let commit = store.selectedCommit {
            GitCommitDetailView(commit: commit, store: store, tab: $commitTab)
        } else {
            ContentUnavailableView("Select a commit", systemImage: "point.3.connected.trianglepath.dotted")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        projectToolbar
        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                store.perform("Fetching…") { await store.fetchRemotes() }
            }
            .help("Fetch all remotes")
            .disabled(store.snapshot.remotes.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button("Pull…", systemImage: "arrow.down.circle") {
                    store.sheet = .pull
                }
                .help(pullHelp)
                .disabled(store.currentBranch == nil)

                Button("Push…", systemImage: "arrow.up.circle") {
                    if let branch = store.currentBranch {
                        store.sheet = .push(.branch(branch))
                    }
                }
                .help("Choose a remote and push options")
                .disabled(store.currentBranch == nil)
            } label: {
                Label("Pull and Push", systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
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
                    pullRequestRefreshCount += 1
                }
            }
            .help("Reload the repository")
        }

        if let suggestion = store.pullRequestSuggestion {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Create Pull Request…", systemImage: "arrow.triangle.pull") {
                        presentCreatePullRequest(suggestion)
                    }
                    Menu {
                        PullRequestDraftModelMenuContent { _ in presentCreatePullRequest(suggestion) }
                    } label: {
                        Label("Draft with Agent", systemImage: "sparkles")
                    }
                } label: {
                    Label("Create PR", systemImage: "arrow.triangle.pull")
                } primaryAction: {
                    presentCreatePullRequest(suggestion)
                }
                .help("\(suggestion.branch) is pushed but has no pull request. Create one with an agent-drafted title and description.")
                .accessibilityIdentifier("git-create-pr-toolbar")
                .popover(isPresented: $showsPullRequestTip, arrowEdge: .bottom) {
                    GitPullRequestTipView(branch: suggestion.branch) {
                        showsPullRequestTip = false
                        presentCreatePullRequest(suggestion)
                    } onDismiss: {
                        GitPullRequestTipLedger.dismiss(suggestion)
                        showsPullRequestTip = false
                    }
                }
            }
        }

        if let checkout = store.gitHubCheckout, let url = gitHubWebURL(forOwnerRepo: checkout.repository) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Open in GitHub", systemImage: "globe") { openURL(url) }
                    if let pullRequestURL {
                        Button("Open Pull Request", systemImage: "arrow.triangle.pull") { openURL(pullRequestURL) }
                    }
                } label: {
                    Label {
                        Text("GitHub")
                    } icon: {
                        Image(.gitHubMark)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
                .menuIndicator(.visible)
                .help("GitHub")
            }
        }
    }

    private var projectToolbar: GitProjectPicker {
        var picker = projectPicker
        picker.branch = store.snapshot.currentBranch
            ?? store.snapshot.headCommit.map { String(localized: "Detached at \(String($0.prefix(7)))") }
            ?? ""
        return picker
    }

    private var pullHelp: String {
        guard let branch = store.currentBranch, let upstream = branch.upstream else {
            return String(localized: "The current branch has no upstream")
        }
        return branch.behind > 0 ? String(localized: "Pull \(branch.behind) commits from \(upstream)") : String(localized: "Pull from \(upstream)")
    }

    private var pullRequestLookup: PullRequestLookup? {
        guard let checkout = store.gitHubCheckout, checkout.branch != nil,
              appState.isSignedIn, let accountID = appState.rxUser?.id else { return nil }
        return PullRequestLookup(checkout: checkout, accountID: accountID, refreshCount: pullRequestRefreshCount)
    }

    private var pullRequestURL: URL? {
        guard let checkout = store.gitHubCheckout, let branch = checkout.branch else { return nil }
        if let pullRequest = appState.pullRequest(forRepository: checkout.repository, branch: branch) {
            return pullRequest.url
        }
        guard case .exists(let url) = store.pullRequestPresence else { return nil }
        return url
    }

    private func presentCreatePullRequest(_ target: GitPullRequestTarget) {
        // Opening the flow counts as acting on the tip.
        GitPullRequestTipLedger.dismiss(target)
        showsPullRequestTip = false
        store.sheet = .createPullRequest(target)
    }

    // MARK: Sheets

    @ViewBuilder private func sheetContent(_ sheet: GitSheet) -> some View {
        switch sheet {
        case .commit(let amend):
            if case .ready(let tree) = repository.state {
                GitWindowCommitSheet(tree: tree, store: store, amend: amend)
            }
        case .pull:
            GitPullSheet(store: store)
        case .push(.branch(let branch)):
            GitPushSheet(store: store, initialBranch: branch)
        case .push(.tag(let tag)):
            GitPushTagSheet(store: store, tag: tag)
        case .createBranch(let start, let label):
            GitCreateBranchSheet(store: store, startPoint: start, label: label)
        case .renameBranch(let name):
            GitRenameBranchSheet(store: store, branch: name)
        case .deleteBranch(let branch):
            GitDeleteBranchSheet(store: store, branch: branch)
        case .createTag(let commit):
            GitCreateTagSheet(store: store, commit: commit)
        case .reword(let commit):
            GitRewordSheet(store: store, commit: commit)
        case .interactiveRebase(let base, let steps):
            GitInteractiveRebaseSheet(store: store, base: base, steps: steps)
        case .stash:
            GitStashSheet(store: store)
        case .editGitIgnore(let patterns):
            GitIgnoreSheet(root: store.root, patterns: patterns, repository: repository)
        case .addRemote:
            GitAddRemoteSheet(store: store)
        case .searchTags:
            GitTagSearchSheet(store: store)
        case .createPullRequest(let target):
            GitCreatePullRequestSheet(store: store, target: target)
        }
    }

    // MARK: Confirmations

    private var confirmationTitle: String {
        guard let confirmation = store.confirmation else { return "" }
        switch confirmation {
        case .reset(_, let mode):
            return String(localized: "Reset \(store.snapshot.currentBranch ?? "HEAD") (\(mode.rawValue))?")
        case .deleteRemoteBranch(let branch): return String(localized: "Delete “\(branch.refName)” from the remote?")
        case .deleteTag(let name): return String(localized: "Delete tag “\(name)”?")
        case .dropStash(let stash): return String(localized: "Drop \(stash.selector)?")
        case .discard(let files): return String(localized: "Discard changes in \(files.count) files?")
        case .removeRemote(let name): return String(localized: "Remove remote “\(name)”?")
        }
    }

    private func confirmationButton(_ confirmation: GitConfirmation) -> String {
        switch confirmation {
        case .reset: String(localized: "Reset")
        case .deleteRemoteBranch, .deleteTag: String(localized: "Delete")
        case .dropStash: String(localized: "Drop")
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
        case .deleteRemoteBranch: return String(localized: "Removes the branch for everyone using this remote.")
        case .deleteTag: return String(localized: "Only the local tag is deleted.")
        case .dropStash(let stash): return stash.message
        case .discard(let files): return files.prefix(8).map(\.displayPath).joined(separator: "\n") + String(localized: "\nThis can’t be undone.")
        case .removeRemote: return String(localized: "Remote-tracking branches for this remote are removed.")
        }
    }

    private func confirm(_ confirmation: GitConfirmation) {
        let root = store.root
        switch confirmation {
        case .reset(let commit, let mode):
            store.perform("Resetting…") { await GitWorkflow.reset(to: commit.id, mode: mode, at: root) }
        case .deleteRemoteBranch(let branch):
            store.perform("Deleting remote branch…") { await GitWorkflow.deleteRemoteBranch(branch, at: root) }
        case .deleteTag(let name):
            store.perform("Deleting tag…") { await GitWorkflow.deleteTag(name, at: root) }
            if store.selection == .tag(name) { store.selection = .allCommits }
        case .dropStash(let stash):
            store.perform("Dropping stash…") { await GitWorkflow.dropStash(stash, at: root) }
            if store.selection == .stash(stash.selector) { store.selection = .allCommits }
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
    let amend: GitAmendDraft?
    @State private var message: String

    init(tree: GitWorkingTree, store: GitWorkflowStore, amend: GitAmendDraft?) {
        self.tree = tree
        self.store = store
        self.amend = amend
        _message = State(initialValue: amend?.message ?? "")
    }

    var body: some View {
        GitCommitSheet(tree: tree, message: $message, amend: amend)
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
        .overlay(alignment: .bottom) { ClaudeThemeDivider() }
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
