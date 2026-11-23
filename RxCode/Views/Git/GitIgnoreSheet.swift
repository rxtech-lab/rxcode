import RxCodeCore
import SwiftUI

struct GitIgnoreSheet: View {
    let root: String
    let patterns: [String]
    let repository: RepositoryStatus

    @Environment(\.dismiss) private var dismiss
    @State private var file: GitIgnoreFile?
    @State private var draft = ""
    @State private var ignoredFiles: Result<[String], Error>?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var loading = true
    @State private var saving = false

    private var hasChanges: Bool {
        guard let file else { return false }
        return !draft.utf8.elementsEqual(file.text.utf8)
    }

    private var operation: LocalizedStringResource? {
        if loading { return "Loading .gitignore…" }
        if saving { return "Saving .gitignore…" }
        return nil
    }

    var body: some View {
        NavigationStack {
            VSplitView {
                patternEditor
                    .frame(minHeight: 180, idealHeight: 245, maxHeight: .infinity)
                ignoredFileList
                    .frame(minHeight: 140, idealHeight: 230, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Edit .gitignore")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasChanges ? "Cancel" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!hasChanges || loading)
                        .accessibilityIdentifier("git-ignore-save")
                }
            }
        }
        .frame(minWidth: 500, idealWidth: 620, maxWidth: .infinity,
               minHeight: 410, idealHeight: 520, maxHeight: .infinity)
        .disabled(saving)
        .interactiveDismissDisabled(saving || hasChanges)
        .overlay { GitOperationOverlay(operation: operation) }
        .task { await load() }
        .alert("Couldn’t save .gitignore", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var patternEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ignore Patterns")
                .font(.headline)
            if let loadError {
                ContentUnavailableView("Couldn’t open .gitignore", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Enter one pattern per line. Rules apply to untracked files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle) }
                    .accessibilityLabel("Ignore Patterns")
                    .accessibilityIdentifier("git-ignore-patterns")
                    .disabled(file == nil || loading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var ignoredFileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Currently Ignored Files")
                .font(.headline)
                .padding(.horizontal, 16)
            switch ignoredFiles {
            case .success(let paths) where paths.isEmpty:
                ContentUnavailableView("No ignored files", systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let paths):
                List(paths.enumerated(), id: \.offset) { entry in
                    HStack(spacing: 6) {
                        GitFileIcon(name: entry.element)
                        Text(verbatim: entry.element)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(entry.element)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("git-ignored-files")
            case .failure(let error):
                ContentUnavailableView("Couldn’t list ignored files", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                Color.clear
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func load() async {
        defer { loading = false }
        do {
            let snapshot = try await GitIgnoreFile.load(at: root)
            file = snapshot
            draft = snapshot.adding(patterns)
        } catch {
            loadError = error.localizedDescription
        }
        await refreshIgnoredFiles()
    }

    private func save() {
        guard let file, hasChanges, !saving, !loading else { return }
        let updatedText = draft
        saving = true
        Task {
            defer { saving = false }
            do {
                self.file = try await file.save(updatedText)
                await refreshIgnoredFiles()
                await repository.refresh(at: root)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func refreshIgnoredFiles() async {
        do {
            ignoredFiles = .success(try await GitIgnoreFile.ignoredPaths(at: root))
        } catch {
            ignoredFiles = .failure(error)
        }
    }
}
