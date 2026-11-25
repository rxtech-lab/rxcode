import RxCodeCore
import SwiftUI

struct GitCommitSheet: View {
    let tree: GitWorkingTree
    @Binding var message: String
    var amend: GitAmendDraft? = nil
    @Environment(AppState.self) private var appState
    @Environment(RepositoryStatus.self) private var repository
    @Environment(\.dismiss) private var dismiss
    @State private var operation: LocalizedStringResource?
    @State private var error: String?
    @State private var selectedPath: String?
    @FocusState private var editingMessage: Bool

    private var canCommit: Bool {
        if let amend, message == amend.message { return true }
        return (amend != nil || !tree.changes.staged.isEmpty)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var checkoutLabel: String {
        guard let amend else { return tree.head }
        let commit = amend.commit.shortID
        return amend.branch.map { "\($0) · \(commit)" } ?? commit
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label(checkoutLabel, systemImage: "arrow.triangle.branch")
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                messageHeader
                TextEditor(text: $message)
                    .font(.body.monospaced())
                    .focused($editingMessage)
                    .padding(4)
                    .frame(minHeight: 90, maxHeight: 150)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle) }
                    .accessibilityLabel("Commit message")
                if tree.changes.staged.isEmpty && (amend?.files.isEmpty ?? true) {
                    ContentUnavailableView(amend == nil ? "No staged files" : "No file changes", systemImage: "tray")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedPath) {
                        if !tree.changes.staged.isEmpty {
                            Section("Staged files (\(tree.changes.staged.count))") {
                                if let changes = tree.changes.trees?.staged {
                                    GitChangedFileTree(changes: changes, tagPrefix: "s:", isSelected: { $0 == selectedPath }) { file in
                                        GitWorkingFileRow(file: file)
                                    }
                                } else {
                                    ForEach(tree.changes.staged) { file in
                                        ChangeFileRow(file: file)
                                            .tag("s:" + file.displayPath)
                                    }
                                }
                            }
                        }
                        if let amend, !amend.files.isEmpty {
                            Section("In original commit (\(amend.files.count))") {
                                GitChangedFileTree(changes: amend.changes, tagPrefix: "c:", isSelected: { $0 == selectedPath }) { file in
                                    GitCommitFileRow(file: file)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: String.self) { selectedTags in
                        let relativePaths = selectedTags.compactMap(Self.relativePath(from:))
                        if !relativePaths.isEmpty {
                            GitFileSystemContextMenuItems(
                                paths: GitFileSystemActions.absolutePaths(for: relativePaths, root: tree.root)
                            )
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(amend == nil ? "Commit changes" : "Amend Commit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(amend == nil ? "Commit" : "Amend") { commit() }
                        .disabled(!canCommit)
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        .disabled(operation != nil)
        .interactiveDismissDisabled(operation != nil)
        .overlay { GitOperationOverlay(operation: operation) }
        .alert("Git operation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { editingMessage = true }
    }

    private nonisolated static func relativePath(from tag: String) -> String? {
        for prefix in ["s:", "c:"] where tag.hasPrefix(prefix) {
            return String(tag.dropFirst(prefix.count))
        }
        return nil
    }

    private var messageHeader: some View {
        @Bindable var appState = appState
        let sections = appState.codingModelSections
        let key = appState.commitMessageModelKey
        let model = sections.lazy.flatMap(\.models).first { $0.key == key }
        let unavailable = !key.isEmpty && model == nil
        return HStack {
            Text("Commit message").font(.headline).fixedSize()
            Spacer(minLength: 4)
            Picker("Commit message model", selection: $appState.commitMessageModelKey) {
                Text("Settings Default").tag("")
                if unavailable {
                    Text("Selected model unavailable").tag(key).disabled(true)
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.key) { model in
                            Text(verbatim: model.displayName).tag(model.key)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .lineLimit(1)
            .frame(maxWidth: 180)
            .help("Commit message model")
            .accessibilityIdentifier("git-commit-model")
            Button("Generate", systemImage: "sparkles") { generate(with: model) }
                .fixedSize()
                .disabled(tree.changes.staged.isEmpty || unavailable)
        }
    }

    private func generate(with model: AgentModel?) {
        guard operation == nil, !tree.changes.staged.isEmpty else { return }
        operation = model.map { "Drafting with \($0.displayName)…" } ?? "Generating message…"
        Task {
            defer { operation = nil }
            async let diff = GitHelper.stagedDiff(at: tree.root)
            async let stat = GitHelper.stagedStat(at: tree.root)
            let summary = tree.changes.staged.map { "\($0.statusChar) \($0.displayPath)" }.joined(separator: "\n")
            do {
                if let result = try await appState.generateCommitMessage(
                    diff: diff, stat: stat, fileSummary: summary, model: model, cwd: tree.root
                ) {
                    message = result
                } else if let model {
                    error = String(localized: "\(model.displayName) couldn't generate a commit message. Try again or choose another model.")
                } else {
                    error = String(localized: "Configure a summarization provider in Settings to generate a commit message.")
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func commit() {
        guard operation == nil, canCommit, let path = repository.path else { return }
        let draft = message
        operation = amend == nil ? "Committing…" : "Amending commit…"
        Task {
            let failure = if let amend {
                await GitWorkflow.amend(
                    message: draft == amend.message ? nil : draft, replacing: amend.commit.id, on: amend.branch, at: tree.root
                )
            } else {
                await GitHelper.commit(message: draft, at: tree.root)
            }
            operation = "Updating file lists…"
            await repository.refresh(at: path)
            operation = nil
            if let failure {
                error = failure
            } else {
                message = ""
                dismiss()
            }
        }
    }
}
