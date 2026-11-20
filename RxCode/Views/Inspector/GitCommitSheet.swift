import RxCodeCore
import SwiftUI

struct GitCommitSheet: View {
    let tree: GitWorkingTree
    @Binding var message: String
    @Environment(AppState.self) private var appState
    @Environment(RepositoryStatus.self) private var repository
    @Environment(\.dismiss) private var dismiss
    @State private var operation: LocalizedStringResource?
    @State private var error: String?
    @FocusState private var editingMessage: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label(tree.head, systemImage: "arrow.triangle.branch")
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Text("Commit message").font(.headline)
                    Spacer()
                    Button("Generate", systemImage: "sparkles") { generate() }
                        .disabled(tree.changes.staged.isEmpty)
                }
                TextEditor(text: $message)
                    .font(.body.monospaced())
                    .focused($editingMessage)
                    .padding(4)
                    .frame(minHeight: 90, maxHeight: 150)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle) }
                    .accessibilityLabel("Commit message")
                Text("Staged files (\(tree.changes.staged.count))").font(.headline)
                List(tree.changes.staged) { file in ChangeFileRow(file: file) }
                    .listStyle(.inset)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Commit changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") { commit() }
                        .disabled(tree.changes.staged.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .disabled(operation != nil)
        .interactiveDismissDisabled(operation != nil)
        .overlay { GitOperationOverlay(operation: operation) }
        .alert("Couldn’t prepare commit", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { editingMessage = true }
    }

    private func generate() {
        guard operation == nil, !tree.changes.staged.isEmpty else { return }
        operation = "Generating message…"
        Task {
            async let diff = GitHelper.stagedDiff(at: tree.root)
            async let stat = GitHelper.stagedStat(at: tree.root)
            let summary = tree.changes.staged.map { "\($0.statusChar) \($0.displayPath)" }.joined(separator: "\n")
            if let result = await appState.generateCommitMessage(diff: diff, stat: stat, fileSummary: summary), !result.isEmpty {
                message = result
            } else {
                error = String(localized: "Configure a summarization provider in Settings to generate a commit message.")
            }
            operation = nil
        }
    }

    private func commit() {
        guard operation == nil, let path = repository.path else { return }
        operation = "Committing…"
        Task {
            error = await GitHelper.commit(message: message, at: tree.root)
            await repository.refresh(at: path)
            operation = nil
            if error == nil {
                message = ""
                dismiss()
            }
        }
    }
}
