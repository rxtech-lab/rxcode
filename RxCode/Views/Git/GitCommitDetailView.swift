import RxCodeChatKit
import RxCodeCore
import SwiftUI

enum GitCommitDetailTab: Hashable {
    case commit, changes, fileTree
}

/// The file list keeps one width so selecting a file never resizes it to fit the detail pane.
private enum GitCommitDetailLayout {
    static let fileListWidth: CGFloat = 280
}

/// Inspector below the history graph for the selected commit.
struct GitCommitDetailView: View {
    let commit: GitCommit
    let store: GitWorkflowStore
    @Binding var tab: GitCommitDetailTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Commit details", selection: $tab) {
                    Text("Commit").tag(GitCommitDetailTab.commit)
                    Text("Changes").tag(GitCommitDetailTab.changes)
                    Text("File Tree").tag(GitCommitDetailTab.fileTree)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text(commit.shortID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(commit.id)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ClaudeTheme.surfacePrimary)
            ClaudeThemeDivider()
            switch tab {
            case .commit:
                ScrollView { summary }
                    .id(commit.id)
            case .changes:
                GitCommitChangesView(commit: commit, root: store.root)
                    .id(commit.id)
            case .fileTree:
                GitCommitFileTreeView(commit: commit, root: store.root)
                    .id(commit.id)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(commit.refs, id: \.self) { GitRefBadge(ref: $0, onCheckout: store.checkout) }
            }
            Text(commit.subject)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                .textSelection(.enabled)
            if !commit.body.isEmpty {
                MarkdownContentView(text: commit.body)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Author").foregroundStyle(ClaudeTheme.textTertiary)
                    Text("\(commit.authorName) <\(commit.authorEmail)>").textSelection(.enabled)
                }
                GridRow {
                    Text("Date").foregroundStyle(ClaudeTheme.textTertiary)
                    Text(commit.authorDate.formatted(date: .complete, time: .standard))
                }
                GridRow {
                    Text("SHA").foregroundStyle(ClaudeTheme.textTertiary)
                    Text(commit.id).font(.system(size: ClaudeTheme.size(11), design: .monospaced)).textSelection(.enabled)
                }
                if !commit.parents.isEmpty {
                    GridRow {
                        Text(commit.parents.count == 1 ? "Parent" : "Parents").foregroundStyle(ClaudeTheme.textTertiary)
                        HStack(spacing: 6) {
                            ForEach(commit.parents, id: \.self) { parent in
                                Button(String(parent.prefix(7))) { store.selectedCommitID = parent }
                                    .buttonStyle(.link)
                                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                                    .disabled(!store.commits.contains { $0.id == parent })
                            }
                        }
                    }
                }
            }
            .font(.system(size: ClaudeTheme.size(11)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GitCommitChangesView: View {
    let commit: GitCommit
    let root: String
    @State private var changes = GitChangedFiles<GitCommitFile>([], path: \.path)
    @State private var selectedPath: String?
    @State private var loading = true

    private var selectedFile: GitCommitFile? {
        selectedPath.flatMap { changes.byPath[$0] }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else if changes.files.isEmpty {
                ContentUnavailableView("No file changes", systemImage: "doc")
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedPath) {
                        GitChangedFileTree(changes: changes, isSelected: { $0 == selectedPath }) { file in
                            GitCommitFileRow(file: file)
                        }
                    }
                    .listStyle(.inset)
                    .frame(width: GitCommitDetailLayout.fileListWidth)
                    .frame(maxHeight: .infinity)
                    ClaudeThemeDivider()

                    Group {
                        if let selectedFile {
                            GitCommitFileDiffView(file: selectedFile, commit: commit, root: root)
                                .id(selectedFile.id)
                        } else if let path = selectedPath, changes.tree.folders.contains(path) {
                            GitFolderContents(folder: path, tree: changes.tree) { selectedPath = $0 }
                        } else {
                            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let changedFiles = await GitChangedFiles.load(in: commit, at: root)
            guard !Task.isCancelled else { return }
            changes = changedFiles
            selectedPath = changedFiles.files.first?.path
            loading = false
        }
    }
}

struct GitCommitFileDiffView: View {
    let file: GitCommitFile
    let commit: GitCommit
    let root: String
    @State private var diffLines: [DiffLine]?

    var body: some View {
        VStack(spacing: 0) {
            GitFilePaneHeader(path: file.path)
            Group {
                if let diffLines {
                    if diffLines.isEmpty {
                        ContentUnavailableView("No textual changes", systemImage: "doc.text.magnifyingglass")
                    } else {
                        DiffView(lines: diffLines, display: .scroll, language: SyntaxHighlighter.language(forFilename: file.name))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            let raw = await GitRepositoryLoader.diff(of: file, in: commit, at: root)
            guard !Task.isCancelled else { return }
            diffLines = DiffComputation.parseUnifiedDiff(raw)
        }
    }
}

private struct GitCommitFileTreeView: View {
    let commit: GitCommit
    let root: String
    @State private var tree: GitPathTree?
    @State private var selectedPath: String?

    var body: some View {
        Group {
            if let tree {
                if tree.roots.isEmpty {
                    ContentUnavailableView("No tracked files", systemImage: "folder")
                } else {
                    HStack(spacing: 0) {
                        List(selection: $selectedPath) {
                            OutlineGroup(tree.roots, children: \.outlineChildren) { node in
                                Label {
                                    Text(node.name).lineLimit(1).truncationMode(.middle)
                                        .foregroundStyle(.primary)
                                } icon: {
                                    GitFileIcon(name: node.name, isFolder: node.isDirectory)
                                }
                                .themedListRow(node.id, selected: node.id == selectedPath)
                                .help(node.id)
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.inset)
                        .frame(width: GitCommitDetailLayout.fileListWidth)
                        .frame(maxHeight: .infinity)
                        ClaudeThemeDivider()
                        Group {
                            if let path = selectedPath {
                                if tree.folders.contains(path) {
                                    GitFolderContents(folder: path, tree: tree) { selectedPath = $0 }
                                } else {
                                    GitCommitFilePreview(path: path, commit: commit, root: root)
                                        .id(path)
                                }
                            } else {
                                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let paths = await GitRepositoryLoader.trackedPaths(in: commit, at: root)
            let loaded = await Task.detached { GitPathTree(paths: paths) }.value
            guard !Task.isCancelled else { return }
            tree = loaded
        }
    }
}

private struct GitCommitFilePreview: View {
    let path: String
    let commit: GitCommit
    let root: String
    @State private var text: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            GitFilePaneHeader(path: path)
            Group {
                if let text {
                    let language = SyntaxHighlighter.language(forFilename: path) ?? ""
                    if ["md", "markdown"].contains(language) {
                        MarkdownPreviewView(content: text)
                    } else {
                        ThemedSourcePreview(text: text, language: language)
                    }
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    ContentUnavailableView("Preview unavailable", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudeTheme.background)
        .task {
            let result = await GitRepositoryLoader.fileText(at: path, in: commit, root: root)
            guard !Task.isCancelled else { return }
            text = result
            loading = false
        }
    }
}

private struct GitFilePaneHeader: View {
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            Label(path, systemImage: "doc.text")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(ClaudeTheme.surfacePrimary)
                .help(path)
            ClaudeThemeDivider()
        }
    }
}
