import RxCodeChatKit
import RxCodeCore
import SwiftUI

enum GitCommitDetailTab: Hashable {
    case commit, changes, fileTree
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
            Divider()
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
                ForEach(commit.refs, id: \.self) { GitRefBadge(ref: $0) }
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
    @State private var files: [GitCommitFile] = []
    @State private var selectedPath: String?
    @State private var loading = true

    private var selectedFile: GitCommitFile? {
        files.first { $0.path == selectedPath }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else if files.isEmpty {
                ContentUnavailableView("No file changes", systemImage: "doc")
            } else {
                HSplitView {
                    List(files, selection: $selectedPath) { file in
                        GitCommitFileRow(file: file).tag(file.path)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 380, maxHeight: .infinity)

                    Group {
                        if let selectedFile {
                            GitCommitFileDiffView(file: selectedFile, commit: commit, root: root)
                                .id(selectedFile.id)
                        } else {
                            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let changedFiles = await GitRepositoryLoader.files(in: commit, at: root)
            guard !Task.isCancelled else { return }
            files = changedFiles
            selectedPath = changedFiles.first?.path
            loading = false
        }
    }
}

private struct GitCommitFileDiffView: View {
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
    @State private var nodes: [FileNode]?
    @State private var selectedPath: String?

    var body: some View {
        Group {
            if let nodes {
                if nodes.isEmpty {
                    ContentUnavailableView("No tracked files", systemImage: "folder")
                } else {
                    HSplitView {
                        List(selection: $selectedPath) {
                            OutlineGroup(nodes, children: \.outlineChildren) { node in
                                Label {
                                    Text(node.name).lineLimit(1).truncationMode(.middle)
                                } icon: {
                                    Image(systemName: node.icon).foregroundStyle(node.iconColor)
                                }
                                .tag(node.id)
                                .help(node.id)
                            }
                        }
                        .listStyle(.inset)
                        .frame(minWidth: 180, idealWidth: 260, maxWidth: 380, maxHeight: .infinity)
                        Group {
                            if let selectedPath {
                                GitCommitFilePreview(path: selectedPath, commit: commit, root: root)
                                    .id(selectedPath)
                            } else {
                                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let paths = await GitRepositoryLoader.trackedPaths(in: commit, at: root)
            let tree = await Task.detached { FileNode.gitTree(paths: paths) }.value
            guard !Task.isCancelled else { return }
            nodes = tree
        }
    }
}

private struct GitCommitFilePreview: View {
    let path: String
    let commit: GitCommit
    let root: String
    @State private var code: SourcePreviewContent?
    @State private var markdown: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            GitFilePaneHeader(path: path)
            Group {
                if let markdown {
                    MarkdownPreviewView(content: markdown)
                } else if let code {
                    CodeTextRenderer(content: code)
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
            if let text = await GitRepositoryLoader.fileText(at: path, in: commit, root: root), !Task.isCancelled {
                if ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) {
                    markdown = text
                } else {
                    let highlighted = await SourcePreviewContent.highlighted(text, language: SyntaxHighlighter.language(forFilename: path) ?? "")
                    guard !Task.isCancelled else { return }
                    code = highlighted
                }
            }
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
            Divider()
        }
    }
}

private extension FileNode {
    var outlineChildren: [Self]? { isDirectory ? children : nil }

    nonisolated static func gitTree(paths: [String], parent: String = "") -> [Self] {
        let components = paths.compactMap { path -> (name: String, remainder: String?)? in
            let parts = path.split(separator: "/", maxSplits: 1)
            guard let name = parts.first else { return nil }
            return (String(name), parts.count == 2 ? String(parts[1]) : nil)
        }
        return Dictionary(grouping: components, by: \.name).map { name, entries in
            let path = parent.isEmpty ? name : "\(parent)/\(name)"
            let children = gitTree(paths: entries.compactMap(\.remainder), parent: path)
            return Self(id: path, name: name, isDirectory: !children.isEmpty, children: children)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct GitCommitFileRow: View {
    let file: GitCommitFile

    private var style: (symbol: String, color: Color) {
        switch file.status {
        case "A": ("plus.circle", ClaudeTheme.statusSuccess)
        case "D": ("minus.circle", ClaudeTheme.statusError)
        case "R": ("arrow.right.circle", ClaudeTheme.accent)
        case "C": ("doc.on.doc", ClaudeTheme.accent)
        default: ("pencil", ClaudeTheme.statusWarning)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbol).foregroundStyle(style.color).frame(width: 16)
            Text(file.name).font(.system(size: ClaudeTheme.size(12), weight: .medium))
            Text(file.originalPath.map { "\($0) → \(file.parentDirectory)" } ?? file.parentDirectory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .help(file.path)
    }
}
