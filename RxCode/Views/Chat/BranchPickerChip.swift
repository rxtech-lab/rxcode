import SwiftUI
import RxCodeCore

// MARK: - BranchPickerChip

/// Sits below the input bar. Shows current branch (or "Work locally") and opens
/// `CreateBranchSheet` so a chat can switch into its own Git worktree.
struct BranchPickerChip: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showCreateSheet = false
    @State private var currentBranch: String?
    @State private var branches: [String] = []
    @State private var switchingTo: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var isInitializingGit = false

    var body: some View {
        Group {
            if shouldShowInitGit {
                initGitButton
            } else {
                branchMenu
            }
        }
        .help(workingDirectoryHint)
        .sheet(isPresented: $showCreateSheet) {
            CreateBranchSheet(currentBranch: currentBranch) {
                refresh()
            }
        }
        .task(id: refreshKey) {
            await refreshNow()
        }
        .onChange(of: refreshKey) { _, _ in refresh() }
    }

    private var shouldShowInitGit: Bool {
        sessionWorktreeBranch == nil && currentBranch == nil
    }

    private var branchMenu: some View {
        Menu {
            if !branches.isEmpty {
                Section("Switch branch") {
                    ForEach(branches, id: \.self) { name in
                        Button {
                            switchToBranch(name)
                        } label: {
                            HStack {
                                if name == activeBranch {
                                    Image(systemName: "checkmark")
                                } else {
                                    Image(systemName: "arrow.triangle.branch")
                                }
                                Text(name)
                            }
                        }
                        .disabled(switchingTo != nil)
                    }
                }
                Divider()
            }
            Button {
                showCreateSheet = true
            } label: {
                Label("Create new branch…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: ClaudeTheme.size(10)))
                Text(displayName)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var initGitButton: some View {
        Button {
            initializeGit()
        } label: {
            HStack(spacing: 4) {
                if isInitializingGit {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: ClaudeTheme.size(10)))
                }
                Text(isInitializingGit ? "Initializing…" : "Initialize Git")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(isInitializingGit)
    }

    private func initializeGit() {
        guard !isInitializingGit else { return }
        guard let path = sessionWorktreePath ?? windowState.selectedProject?.path else { return }
        isInitializingGit = true
        Task {
            _ = await GitHelper.initRepository(at: path)
            isInitializingGit = false
            refresh()
        }
    }

    private var activeBranch: String? {
        sessionWorktreeBranch ?? currentBranch
    }

    private func switchToBranch(_ branch: String) {
        guard switchingTo == nil, branch != activeBranch else { return }
        switchingTo = branch
        Task {
            do {
                try await appState.switchToExistingBranch(branch, in: windowState)
            } catch {
                // Surface failures through the existing logging path; the chip
                // simply reverts to the prior state on the next refresh.
            }
            switchingTo = nil
            refresh()
        }
    }

    private var refreshKey: String {
        let project = windowState.selectedProject?.path ?? ""
        let session = windowState.currentSessionId ?? "__new__"
        return project + "|" + session
    }

    private var sessionWorktreePath: String? {
        if let sid = windowState.currentSessionId {
            return appState.sessionStates[sid]?.worktreePath
                ?? appState.allSessionSummaries.first(where: { $0.id == sid })?.worktreePath
        }
        return windowState.pendingWorktreePath
    }

    private var sessionWorktreeBranch: String? {
        if let sid = windowState.currentSessionId {
            return appState.sessionStates[sid]?.worktreeBranch
                ?? appState.allSessionSummaries.first(where: { $0.id == sid })?.worktreeBranch
        }
        return windowState.pendingWorktreeBranch
    }

    private var displayName: String {
        if let b = sessionWorktreeBranch { return b }
        if let b = currentBranch { return b }
        return ""
    }

    private var workingDirectoryHint: String {
        if let p = sessionWorktreePath { return "Worktree: \(p)" }
        return "Working in project root. Click to create a worktree."
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refreshNow() }
    }

    private func refreshNow() async {
        let path = sessionWorktreePath ?? windowState.selectedProject?.path
        guard let path else {
            currentBranch = nil
            branches = []
            return
        }
        let branch = await GitHelper.currentBranch(at: path)
        let listPath = windowState.selectedProject?.path ?? path
        let list = await GitHelper.listLocalBranches(at: listPath)
        if !Task.isCancelled {
            currentBranch = branch
            branches = list
        }
    }
}

// MARK: - CreateBranchSheet

struct CreateBranchSheet: View {
    /// How a new branch gets materialized for the chat.
    enum BranchMode: String, CaseIterable, Identifiable {
        /// `git worktree add -b` — isolated checkout in a sibling directory.
        case worktree
        /// `git checkout -b` in the project root — mutates the main repo.
        case checkout

        var id: String { rawValue }

        var label: String {
            switch self {
            case .worktree: "New worktree"
            case .checkout: "Branch + checkout"
            }
        }

        var hint: String {
            switch self {
            case .worktree:
                "Creates an isolated worktree so this chat works without touching the main checkout."
            case .checkout:
                "Creates the branch and checks it out in the project root, changing the main checkout."
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let currentBranch: String?
    let onCreated: () -> Void

    @State private var branchText: String = "rxcode/"
    @State private var mode: BranchMode = .worktree
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var validationError: String? {
        let trimmed = branchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Branch name is required." }
        if trimmed.hasSuffix("/") { return "Branch name cannot end with “/”." }
        if trimmed == "rxcode/" { return "Add a branch name after the prefix." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create branch")
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Branch name")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Spacer()
                    if let base = currentBranch {
                        Text("from \(base)")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }

                TextField("rxcode/feature-name", text: $branchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(14), design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
                    )
                    .focused($isFocused)
                    .disabled(isCreating)
                    .onSubmit { submit() }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.statusError)
                } else if let v = validationError {
                    Text(v)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $mode) {
                    ForEach(BranchMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isCreating)

                Text(mode.hint)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Button {
                    submit()
                } label: {
                    if isCreating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Creating…")
                        }
                    } else {
                        Text(mode == .worktree ? "Create worktree" : "Create and checkout")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil || isCreating)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(ClaudeTheme.background)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private func submit() {
        let trimmed = branchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validationError == nil else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                switch mode {
                case .worktree:
                    try await appState.attachWorktree(branch: trimmed, in: windowState)
                case .checkout:
                    try await appState.createBranchInPlace(branch: trimmed, in: windowState)
                }
                isCreating = false
                onCreated()
                dismiss()
            } catch {
                isCreating = false
                errorMessage = (error as? GitWorktreeService.WorktreeError)?.description ?? error.localizedDescription
            }
        }
    }
}
