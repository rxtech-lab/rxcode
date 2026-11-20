import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Working tree changes: stage, unstage, discard, stash, and commit.
struct GitLocalChangesView: View {
    let store: GitWorkflowStore
    @Binding var selectedChange: GitChangeFile?
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

    private static func tag(_ file: GitChangeFile) -> String {
        (file.diffMode == .staged ? "s:" : "u:") + file.displayPath
    }

    private func content(_ tree: GitWorkingTree) -> some View {
        let unstaged = tree.changes.unstaged
        let staged = tree.changes.staged
        let all = unstaged + staged
        let selected = all.filter { selection.contains(Self.tag($0)) }
        return VStack(spacing: 0) {
            if all.isEmpty {
                ContentUnavailableView("Working tree clean", systemImage: "checkmark.circle",
                                       description: Text("There are no uncommitted changes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if !unstaged.isEmpty {
                        Section {
                            ForEach(unstaged) { ChangeFileRow(file: $0).tag(Self.tag($0)) }
                        } header: {
                            sectionHeader("Unstaged", count: unstaged.count, action: "Stage All") {
                                stage(unstaged, tree: tree)
                            }
                        }
                    }
                    if !staged.isEmpty {
                        Section {
                            ForEach(staged) { ChangeFileRow(file: $0).tag(Self.tag($0)) }
                        } header: {
                            sectionHeader("Staged", count: staged.count, action: "Unstage All") {
                                unstage(staged, tree: tree)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { tags in
                    let files = all.filter { tags.contains(Self.tag($0)) }
                    let unstagedFiles = files.filter { $0.diffMode != .staged }
                    let stagedFiles = files.filter { $0.diffMode == .staged }
                    if !unstagedFiles.isEmpty {
                        Button("Stage") { stage(unstagedFiles, tree: tree) }
                        Button("Discard Changes…", role: .destructive) { store.confirmation = .discard(unstagedFiles) }
                    }
                    if !stagedFiles.isEmpty {
                        Button("Unstage") { unstage(stagedFiles, tree: tree) }
                    }
                } primaryAction: { tags in
                    let files = all.filter { tags.contains(Self.tag($0)) }
                    if files.allSatisfy({ $0.diffMode != .staged }) {
                        stage(files, tree: tree)
                    } else if files.allSatisfy({ $0.diffMode == .staged }) {
                        unstage(files, tree: tree)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Stage") { stage(selected.filter { $0.diffMode != .staged }, tree: tree) }
                    .disabled(!selected.contains { $0.diffMode != .staged })
                Button("Unstage") { unstage(selected.filter { $0.diffMode == .staged }, tree: tree) }
                    .disabled(!selected.contains { $0.diffMode == .staged })
                Button("Discard…") { store.confirmation = .discard(selected.filter { $0.diffMode != .staged }) }
                    .disabled(!selected.contains { $0.diffMode != .staged })
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
        .onChange(of: selection) {
            let files = all.filter { selection.contains(Self.tag($0)) }
            selectedChange = files.count == 1 ? files.first : nil
        }
        .onChange(of: all) {
            selection.formIntersection(all.map(Self.tag))
            if let current = selectedChange, !all.contains(current) { selectedChange = nil }
        }
    }

    private func sectionHeader(_ title: LocalizedStringResource, count: Int, action: LocalizedStringResource, perform: @escaping () -> Void) -> some View {
        HStack {
            Text("\(String(localized: title)) (\(count))")
            Spacer()
            Button(String(localized: action), action: perform)
                .buttonStyle(.link)
                .font(.caption)
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
struct GitLocalChangeDiffView: View {
    let file: GitChangeFile?

    var body: some View {
        if let file {
            FileDiffView(filePath: file.path, fileName: file.name, gitDiffMode: file.diffMode)
                .id("\(file.diffMode)-\(file.path)")
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Choose one changed file to see its diff."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
