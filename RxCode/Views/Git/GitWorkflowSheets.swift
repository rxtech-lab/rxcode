import RxCodeCore
import SwiftUI

/// Runs a sheet action, keeps the sheet open on failure, and refreshes the Git window.
struct GitSheetOperation<Content: View>: View {
    let store: GitWorkflowStore
    let progressTitle: LocalizedStringResource
    let action: () async -> String?
    @ViewBuilder let content: (_ submit: @escaping () -> Void) -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var error: String?

    var body: some View {
        content(run)
            .disabled(running)
            .interactiveDismissDisabled(running)
            .overlay { GitOperationOverlay(operation: running ? progressTitle : nil) }
            .alert("Git operation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            let failure = await action()
            await store.reload()
            running = false
            if let failure {
                error = failure
            } else {
                dismiss()
            }
        }
    }
}

private struct GitFormSheet<Content: View>: View {
    let title: LocalizedStringResource
    let confirmTitle: LocalizedStringResource
    let progressTitle: LocalizedStringResource
    let canConfirm: Bool
    let store: GitWorkflowStore
    let action: () async -> String?
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GitSheetOperation(store: store, progressTitle: progressTitle, action: action) { submit in
            NavigationStack {
                Form { content() }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(Text(title))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: confirmTitle), action: submit)
                                .disabled(!canConfirm)
                        }
                    }
            }
            .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity, minHeight: 320, idealHeight: 380, maxHeight: .infinity)
        }
    }
}

struct GitPullSheet: View {
    let store: GitWorkflowStore
    @State private var strategy: GitWorkflow.PullStrategy = .fastForwardOnly

    var body: some View {
        let branch = store.currentBranch
        GitFormSheet(
            title: "Pull Branch",
            confirmTitle: "Pull",
            progressTitle: "Pulling…",
            canConfirm: branch?.upstream != nil,
            store: store,
            action: { await GitWorkflow.pull(strategy, at: store.root) }
        ) {
            if let branch {
                LabeledContent("Branch", value: branch.name)
                if let upstream = branch.upstream {
                    LabeledContent("Upstream", value: upstream)
                } else {
                    LabeledContent("Upstream") {
                        Button("Create Remote…") { store.sheet = .push(.branch(branch)) }
                    }
                }
            }
            Picker("Strategy", selection: $strategy) {
                Text("Fast-forward Only").tag(GitWorkflow.PullStrategy.fastForwardOnly)
                Text("Merge").tag(GitWorkflow.PullStrategy.merge)
                Text("Rebase").tag(GitWorkflow.PullStrategy.rebase)
            }
            .pickerStyle(.radioGroup)
            .disabled(branch?.upstream == nil)
        }
    }
}

struct GitPushTagSheet: View {
    let store: GitWorkflowStore
    let tag: GitTag
    @State private var remote: String?

    init(store: GitWorkflowStore, tag: GitTag) {
        self.store = store
        self.tag = tag
        _remote = State(initialValue: store.defaultRemote)
    }

    var body: some View {
        GitFormSheet(
            title: "Push Tag",
            confirmTitle: "Push",
            progressTitle: "Pushing…",
            canConfirm: remote.map(store.snapshot.remotes.contains) == true,
            store: store,
            action: {
                guard let remote else { return String(localized: "Select a remote before pushing.") }
                return await GitWorkflow.pushTag(tag.name, remote: remote, at: store.root)
            }
        ) {
            LabeledContent("Tag", value: tag.name)
            Picker("Remote", selection: $remote) {
                if remote == nil { Text("Select a remote").tag(nil as String?) }
                ForEach(store.snapshot.remotes, id: \.self) { Text($0).tag(Optional($0)) }
            }
        }
    }
}

private func isValidRefName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed == name, !name.hasPrefix("-"), !name.hasSuffix("/"), !name.hasSuffix(".lock") else { return false }
    let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
    return name.rangeOfCharacter(from: forbidden) == nil && !name.contains("..") && !name.contains("@{")
}

struct GitCreateBranchSheet: View {
    let store: GitWorkflowStore
    let startPoint: String
    let label: String
    @State private var name = ""
    @State private var checkout = true

    var body: some View {
        GitFormSheet(
            title: "New Branch",
            confirmTitle: "Create Branch",
            progressTitle: "Creating branch…",
            canConfirm: isValidRefName(name),
            store: store,
            action: { await GitWorkflow.createBranch(name, at: startPoint, checkout: checkout, root: store.root) }
        ) {
            LabeledContent("Starting point", value: label)
            TextField("Branch name", text: $name, prompt: Text("feature/my-change"))
            Toggle("Check out after creating", isOn: $checkout)
        }
    }
}

struct GitRenameBranchSheet: View {
    let store: GitWorkflowStore
    let branch: String
    @State private var name: String

    init(store: GitWorkflowStore, branch: String) {
        self.store = store
        self.branch = branch
        _name = State(initialValue: branch)
    }

    var body: some View {
        GitFormSheet(
            title: "Rename Branch",
            confirmTitle: "Rename",
            progressTitle: "Renaming branch…",
            canConfirm: isValidRefName(name) && name != branch,
            store: store,
            action: { await GitWorkflow.renameBranch(branch, to: name, at: store.root) }
        ) {
            LabeledContent("Current name", value: branch)
            TextField("New name", text: $name)
        }
    }
}

struct GitCreateTagSheet: View {
    let store: GitWorkflowStore
    let commit: GitCommit
    @State private var name = ""
    @State private var message = ""

    var body: some View {
        GitFormSheet(
            title: "New Tag",
            confirmTitle: "Create Tag",
            progressTitle: "Creating tag…",
            canConfirm: isValidRefName(name),
            store: store,
            action: { await GitWorkflow.createTag(name, at: commit.id, message: message, root: store.root) }
        ) {
            LabeledContent("Commit", value: "\(commit.shortID) \(commit.subject)")
            TextField("Tag name", text: $name, prompt: Text("v1.0.0"))
            Section("Annotation (optional)") {
                TextEditor(text: $message)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
            }
        }
    }
}

struct GitTagSearchSheet: View {
    let store: GitWorkflowStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [GitTag] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? store.snapshot.tags : store.snapshot.tags.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let tags = results
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search tags", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(12)
                Divider()
                if tags.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(tags) { tag in
                        Button {
                            store.selection = .tag(tag.name)
                            dismiss()
                        } label: {
                            GitTagRow(tag: tag)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Search Tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .defaultFocus($searchFocused, true)
        }
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity, minHeight: 320, idealHeight: 480, maxHeight: .infinity)
    }
}

struct GitRewordSheet: View {
    let store: GitWorkflowStore
    let commit: GitCommit
    @State private var message: String

    init(store: GitWorkflowStore, commit: GitCommit) {
        self.store = store
        self.commit = commit
        _message = State(initialValue: commit.fullMessage)
    }

    var body: some View {
        GitFormSheet(
            title: "Reword Commit",
            confirmTitle: "Reword",
            progressTitle: "Rewording commit…",
            canConfirm: !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message != commit.fullMessage,
            store: store,
            action: { await GitWorkflow.reword(commit, message: message, at: store.root) }
        ) {
            LabeledContent("Commit", value: commit.shortID)
            Section("Message") {
                TextEditor(text: $message)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .accessibilityLabel("Commit message")
            }
            if commit.id != store.snapshot.headCommit {
                Text("Rewording an older commit rewrites every commit after it. Force push if the branch is already published.")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
        }
    }
}

struct GitStashSheet: View {
    let store: GitWorkflowStore
    @State private var message = ""
    @State private var includeUntracked = true

    var body: some View {
        GitFormSheet(
            title: "Stash Changes",
            confirmTitle: "Stash",
            progressTitle: "Stashing changes…",
            canConfirm: true,
            store: store,
            action: { await GitWorkflow.stash(message: message, includeUntracked: includeUntracked, at: store.root) }
        ) {
            TextField("Message", text: $message, prompt: Text("Optional description"))
            Toggle("Include untracked files", isOn: $includeUntracked)
        }
    }
}

struct GitAddRemoteSheet: View {
    let store: GitWorkflowStore
    let onAdded: (String) -> Void
    @State private var name: String
    @State private var url = ""
    @State private var added = false

    init(store: GitWorkflowStore, onAdded: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.onAdded = onAdded
        _name = State(initialValue: store.snapshot.remotes.isEmpty ? "origin" : "")
    }

    var body: some View {
        GitFormSheet(
            title: "Add Remote",
            confirmTitle: "Add Remote",
            progressTitle: "Adding remote…",
            canConfirm: isValidRefName(name) && !url.trimmingCharacters(in: .whitespaces).isEmpty,
            store: store,
            action: {
                if !added {
                    if let failure = await GitWorkflow.addRemote(name: name, url: url.trimmingCharacters(in: .whitespaces), at: store.root) {
                        return failure
                    }
                    added = true
                    onAdded(name)
                }
                return await GitHelper.runWithError(["fetch", "--", name], at: store.root)
            }
        ) {
            TextField("Name", text: $name, prompt: Text(store.snapshot.remotes.isEmpty ? "origin" : "upstream"))
                .disabled(added)
            TextField("URL", text: $url, prompt: Text("git@github.com:owner/repo.git"))
                .disabled(added)
        }
    }
}

// MARK: - Interactive Rebase

struct GitInteractiveRebaseSheet: View {
    let store: GitWorkflowStore
    let base: GitCommit
    @State private var steps: [GitRebaseStep]
    @State private var path: [String] = []
    @State private var running = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: GitWorkflowStore, base: GitCommit, steps: [GitRebaseStep]) {
        self.store = store
        self.base = base
        // Newest first, matching the history graph; the plan runs oldest first.
        _steps = State(initialValue: steps.reversed())
    }

    private var plan: [GitRebaseStep] { steps.reversed() }
    private var validation: GitRebasePlan.ValidationError? { GitRebasePlan.validate(plan) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach($steps) { $step in
                            GitRebaseStepRow(step: $step)
                        }
                        .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Newest commit first. Drag to reorder.")
                    } footer: {
                        if let validation { Text(message(for: validation)).foregroundStyle(ClaudeTheme.statusError) }
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Text("Rebasing \(steps.count) commits onto \(base.parents.first.map { String($0.prefix(7)) } ?? String(localized: "the root"))")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Spacer()
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Interactive Rebase")
            .navigationDestination(for: String.self) { id in
                if let index = steps.firstIndex(where: { $0.commit == id }) {
                    GitRebaseMessageEditor(step: $steps[index])
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Rebase") { run() }
                        .disabled(validation != nil || running)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, maxWidth: .infinity, minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .disabled(running)
        .interactiveDismissDisabled(running)
        .overlay { GitOperationOverlay(operation: running ? "Rebasing…" : nil) }
        .alert("Rebase stopped", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil; dismiss() }
        } message: { Text(error ?? "") }
    }

    private func message(for error: GitRebasePlan.ValidationError) -> String {
        switch error {
        case .empty: String(localized: "Keep at least one commit.")
        case .squashWithoutTarget: String(localized: "The oldest kept commit can’t be squashed or fixed up.")
        case .emptyRewordMessage: String(localized: "Reworded commits need a message.")
        }
    }

    private func run() {
        running = true
        let plan = plan
        Task {
            let failure = await GitWorkflow.interactiveRebase(plan, base: base.parents.first, at: store.root)
            await store.reload()
            running = false
            if let failure {
                // A paused rebase continues from the window's banner.
                error = failure
            } else {
                dismiss()
            }
        }
    }
}

private struct GitRebaseStepRow: View {
    @Binding var step: GitRebaseStep

    var body: some View {
        HStack(spacing: 10) {
            Picker("Action", selection: $step.action) {
                ForEach(GitRebaseStep.Action.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Text(String(step.commit.prefix(7)))
                .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(step.action == .reword ? firstLine(step.message) : step.subject)
                .strikethrough(step.action == .drop)
                .foregroundStyle(step.action == .drop ? ClaudeTheme.textTertiary : ClaudeTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if step.action == .reword {
                NavigationLink(value: step.commit) {
                    Label("Edit Message", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func firstLine(_ message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}

private struct GitRebaseMessageEditor: View {
    @Binding var step: GitRebaseStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original: \(step.subject)")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textSecondary)
            TextEditor(text: $step.message)
                .font(.body.monospaced())
                .padding(4)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle) }
                .accessibilityLabel("Commit message")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Edit Message")
    }
}

extension GitRebaseStep.Action {
    var title: LocalizedStringResource {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .drop: "Drop"
        }
    }
}
