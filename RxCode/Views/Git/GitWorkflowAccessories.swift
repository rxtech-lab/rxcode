import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Pending operation banner

struct GitPendingOperationBanner: View {
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

struct GitStashSummaryView: View {
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

struct GitStashDiffView: View {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
