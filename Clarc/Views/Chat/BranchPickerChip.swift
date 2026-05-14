import SwiftUI
import ClarcCore

// MARK: - BranchPickerChip

/// Sits below the input bar. Shows current branch (or "Work locally") and opens
/// `CreateBranchSheet` so a chat can switch into its own Git worktree.
struct BranchPickerChip: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showCreateSheet = false
    @State private var currentBranch: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Button {
            showCreateSheet = true
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
        .buttonStyle(.plain)
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

    private var refreshKey: String {
        let project = windowState.selectedProject?.path ?? ""
        let session = windowState.currentSessionId ?? "__new__"
        return project + "|" + session
    }

    private var sessionWorktreePath: String? {
        guard let sid = windowState.currentSessionId else { return nil }
        return appState.sessionStates[sid]?.worktreePath
            ?? appState.allSessionSummaries.first(where: { $0.id == sid })?.worktreePath
    }

    private var sessionWorktreeBranch: String? {
        guard let sid = windowState.currentSessionId else { return nil }
        return appState.sessionStates[sid]?.worktreeBranch
            ?? appState.allSessionSummaries.first(where: { $0.id == sid })?.worktreeBranch
    }

    private var displayName: String {
        if let b = sessionWorktreeBranch { return b }
        if let b = currentBranch { return b }
        return "Work locally"
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
            return
        }
        let branch = await GitHelper.currentBranch(at: path)
        if !Task.isCancelled { currentBranch = branch }
    }
}

// MARK: - CreateBranchSheet

struct CreateBranchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let currentBranch: String?
    let onCreated: () -> Void

    @State private var branchText: String = "clarc/"
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var validationError: String? {
        let trimmed = branchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Branch name is required." }
        if trimmed.hasSuffix("/") { return "Branch name cannot end with “/”." }
        if trimmed == "clarc/" { return "Add a branch name after the prefix." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create and checkout branch")
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

                TextField("clarc/feature-name", text: $branchText)
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
                        Text("Create and checkout")
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
                try await appState.attachWorktree(branch: trimmed, in: windowState)
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
