import RxCodeChatKit
import RxCodeCore
import SwiftUI

enum GitCommitDetailTab: Hashable {
    case commit, changes, fileTree
}

enum GitFileDetailMode: Hashable {
    case diff, preview
}

struct GitFileDetailModePicker: View {
    @Binding var mode: GitFileDetailMode

    var body: some View {
        Picker("View", selection: $mode) {
            Text("Diff").tag(GitFileDetailMode.diff)
            Text("Preview").tag(GitFileDetailMode.preview)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("git-file-detail-mode")
    }
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
                GitRefBadges(refs: commit.refs, snapshot: store.snapshot, onCheckout: store.checkout)
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
    @State private var detailMode: GitFileDetailMode = .diff
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedPath) {
                        GitChangedFileTree(changes: changes, isSelected: { $0 == selectedPath }) { file in
                            GitCommitFileRow(file: file)
                        }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: String.self) { selectedPaths in
                        if selectedPaths.count == 1, let path = selectedPaths.first, changes.byPath[path] != nil {
                            Button("Show Diff", systemImage: "arrow.left.arrow.right") {
                                selectedPath = path
                                detailMode = .diff
                            }
                            Button("Show Preview", systemImage: "eye") {
                                selectedPath = path
                                detailMode = .preview
                            }
                            Divider()
                        }
                        if !selectedPaths.isEmpty {
                            GitFileSystemContextMenuItems(
                                paths: GitFileSystemActions.absolutePaths(for: Array(selectedPaths), root: root)
                            )
                        }
                    }
                    .frame(width: GitCommitDetailLayout.fileListWidth)
                    .frame(maxHeight: .infinity)
                    ClaudeThemeDivider()

                    Group {
                        if let selectedFile {
                            GitCommitFileDiffView(file: selectedFile, commit: commit, root: root, mode: $detailMode)
                                .id(selectedFile.id)
                        } else if let path = selectedPath, changes.tree.folders.contains(path) {
                            GitFolderContents(folder: path, root: root, tree: changes.tree) { selectedPath = $0 }
                        } else {
                            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @Binding var mode: GitFileDetailMode
    @State private var diffLines: [DiffLine]?

    var body: some View {
        VStack(spacing: 0) {
            GitFilePaneHeader(path: file.path) {
                GitFileDetailModePicker(mode: $mode)
            }
            Group {
                switch mode {
                case .diff:
                    if let diffLines {
                        if diffLines.isEmpty {
                            ContentUnavailableView("No textual changes", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            DiffView(lines: diffLines, display: .scroll, language: SyntaxHighlighter.language(forFilename: file.name))
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .preview:
                    if file.status == "D" {
                        ContentUnavailableView(
                            "File deleted",
                            systemImage: "trash",
                            description: Text("This file was deleted in \(commit.shortID).")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GitCommitFilePreviewContent(path: file.path, commit: commit, root: root)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudeTheme.background)
        .task(id: mode == .diff) {
            guard mode == .diff, diffLines == nil else { return }
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .contextMenu(forSelectionType: String.self) { selectedPaths in
                            if !selectedPaths.isEmpty {
                                GitFileSystemContextMenuItems(
                                    paths: GitFileSystemActions.absolutePaths(for: Array(selectedPaths), root: root)
                                )
                            }
                        }
                        .frame(width: GitCommitDetailLayout.fileListWidth)
                        .frame(maxHeight: .infinity)
                        ClaudeThemeDivider()
                        Group {
                            if let path = selectedPath {
                                if tree.folders.contains(path) {
                                    GitFolderContents(folder: path, root: root, tree: tree) { selectedPath = $0 }
                                } else {
                                    GitCommitFilePreview(path: path, commit: commit, root: root)
                                        .id(path)
                                }
                            } else {
                                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        VStack(spacing: 0) {
            GitFilePaneHeader(path: path)
            GitCommitFilePreviewContent(path: path, commit: commit, root: root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudeTheme.background)
    }
}

private struct GitCommitFilePreviewContent: View {
    private enum LoadedContent {
        case text(String)
        case markdown(String)
        case html(URL, String)
        case native(URL)
        case unavailable
    }

    let path: String
    let commit: GitCommit
    let root: String
    @State private var loaded: LoadedContent?
    @State private var tempDirectory: URL?
    @State private var capture = PreviewCapture()

    private var fileName: String { (path as NSString).lastPathComponent }
    private var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    var body: some View {
        Group {
            switch loaded {
            case .text(let text):
                ThemedSourcePreview(text: text, language: fileExtension)
            case .markdown(let text):
                MarkdownPreviewView(content: text)
            case .html(let url, let text):
                HTMLFilePreviewView(fileURL: url, content: text)
            case .native(let url):
                NativeFilePreviewView(fileURL: url, capture: capture)
            case .unavailable:
                ContentUnavailableView("Preview unavailable", systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(commit.id):\(path)") {
            await loadContent()
        }
        .onDisappear {
            cleanupTempDirectory()
        }
    }

    private func loadContent() async {
        cleanupTempDirectory()
        loaded = nil

        let format = FilePreviewFormat(fileName: fileName)
        let maxBytes = format == .native ? 20 * 1024 * 1024 : 5 * 1024 * 1024
        guard let data = await GitRepositoryLoader.fileData(at: path, in: commit, root: root, maxBytes: maxBytes) else {
            guard !Task.isCancelled else { return }
            loaded = .unavailable
            return
        }
        guard !Task.isCancelled else { return }

        if format == .markdown, let text = FilePreviewFormat.decodeSource(data) {
            loaded = .markdown(text)
            return
        }
        if format == .text, let text = FilePreviewFormat.decodeSource(data) {
            loaded = .text(text)
            return
        }

        let name = fileName
        let written = await Task.detached(priority: .userInitiated) { () -> (directory: URL, fileURL: URL)? in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rxcode-git-preview-\(UUID().uuidString)", isDirectory: true)
            let fileURL = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                return (directory, fileURL)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        }.value

        guard !Task.isCancelled else {
            if let directory = written?.directory {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
            }
            return
        }

        if let written {
            tempDirectory = written.directory
            if format == .html, let text = FilePreviewFormat.decodeSource(data) {
                loaded = .html(written.fileURL, text)
            } else {
                loaded = .native(written.fileURL)
            }
        } else if let text = FilePreviewFormat.decodeSource(data) {
            loaded = .text(text)
        } else {
            loaded = .unavailable
        }
    }

    private func cleanupTempDirectory() {
        guard let directory = tempDirectory else { return }
        tempDirectory = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private struct GitFilePaneHeader<Leading: View>: View {
    let path: String
    @ViewBuilder let leading: () -> Leading

    init(path: String, @ViewBuilder leading: @escaping () -> Leading) {
        self.path = path
        self.leading = leading
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                leading()
                Label(path, systemImage: "doc.text")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ClaudeTheme.surfacePrimary)
            ClaudeThemeDivider()
        }
    }
}

private extension GitFilePaneHeader where Leading == EmptyView {
    init(path: String) {
        self.init(path: path) { EmptyView() }
    }
}
