import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Working tree changes: stage, unstage, discard, stash, and commit.
struct GitLocalChangesView: View {
    let store: GitWorkflowStore
    @Environment(RepositoryStatus.self) private var repository
    @State private var selection = Set<String>()

    var body: some View {
        switch repository.state {
        case .ready(let tree):
            content(tree)
        case .loading:
            ProgressView("Checking repository…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository, .unavailable:
            ContentUnavailableView("Repository unavailable", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private nonisolated static func tag(_ file: GitChangeFile) -> String {
        (file.diffMode == .staged ? "s:" : "u:") + file.displayPath
    }

    private func content(_ tree: GitWorkingTree) -> some View {
        let unstaged = tree.changes.unstaged
        let staged = tree.changes.staged
        let all = unstaged + staged
        let selected = all.filter { selection.contains(Self.tag($0)) }
        let discardable = selected.filter { $0.diffMode != .staged }
        return VStack(spacing: 0) {
            if all.isEmpty {
                ContentUnavailableView("Working tree clean", systemImage: "checkmark.circle",
                                       description: Text("There are no uncommitted changes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VSplitView {
                        changesPane(files: unstaged, staged: false) { stage($0, tree: tree) }
                            .frame(minHeight: 100, idealHeight: 330, maxHeight: .infinity)
                        changesPane(files: staged, staged: true) { unstage($0, tree: tree) }
                            .frame(minHeight: 100, idealHeight: 240, maxHeight: .infinity)
                    }
                    .frame(minWidth: 190, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
                    GitLocalChangeDiffView(file: selected.count == 1 ? selected.first : nil) {
                        selection.removeAll()
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 8) {
                    Button("Discard…") { store.confirmation = .discard(discardable) }
                        .disabled(discardable.isEmpty)
                    Spacer(minLength: 0)
                    Button("Commit…") { store.sheet = .commit }
                        .buttonStyle(.borderedProminent)
                        .tint(ClaudeTheme.accent)
                        .disabled(staged.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .controlSize(.small)
                .padding(10)
            }
        }
        .onChange(of: all) {
            selection.formIntersection(all.map(Self.tag))
        }
    }

    private func changesPane(
        files: [GitChangeFile],
        staged: Bool,
        update: @escaping ([GitChangeFile]) -> Void
    ) -> some View {
        let tags = Set(files.map(Self.tag))
        let selected = files.filter { selection.contains(Self.tag($0)) }
        let action: LocalizedStringResource = staged ? "Unstage" : "Stage"
        let bulkAction: LocalizedStringResource = staged ? "Unstage All" : "Stage All"

        return VStack(spacing: 0) {
            HStack {
                Text(staged ? "Staged" : "Unstaged")
                    .font(.subheadline.weight(.semibold))
                Text("\(files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: selected.isEmpty ? bulkAction : action)) {
                    update(selected.isEmpty ? files : selected)
                }
                .controlSize(.small)
                .disabled(files.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ClaudeTheme.surfacePrimary)
            Divider()
            if files.isEmpty {
                Text(staged ? "No staged files" : "No unstaged files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files, selection: Binding(get: { selection.intersection(tags) }, set: { selection = $0 })) { file in
                    ChangeFileRow(file: file).tag(Self.tag(file))
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { selectedTags in
                    if !selectedTags.isEmpty {
                        let targets = files.filter { selectedTags.contains(Self.tag($0)) }
                        Button(String(localized: action)) { update(targets) }
                        if !staged {
                            Button("Discard Changes…", role: .destructive) { store.confirmation = .discard(targets) }
                        }
                    }
                } primaryAction: { selectedTags in
                    update(files.filter { selectedTags.contains(Self.tag($0)) })
                }
            }
        }
    }

    private func stage(_ files: [GitChangeFile], tree: GitWorkingTree) {
        let paths = files.flatMap(\.pathspecs)
        guard !paths.isEmpty else { return }
        store.perform("Staging files…") { await GitHelper.stage(paths: paths, at: tree.root) }
    }

    private func unstage(_ files: [GitChangeFile], tree: GitWorkingTree) {
        let paths = files.flatMap(\.pathspecs)
        guard !paths.isEmpty else { return }
        store.perform("Unstaging files…") { await GitHelper.unstage(paths: paths, at: tree.root) }
    }
}

/// Detail column for a working tree file.
private struct GitLocalChangeDiffView: View {
    let file: GitChangeFile?
    let onClose: () -> Void

    var body: some View {
        if let file {
            FileDiffView(filePath: file.path, fileName: file.name, gitDiffMode: file.diffMode, onClose: onClose)
                .id("\(file.diffMode)-\(file.path)")
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Choose one changed file to see its diff."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
