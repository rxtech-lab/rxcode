import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Keep the tree and its lookup together so a status refresh replaces them atomically.
nonisolated struct GitChangedFiles<File: Equatable & Sendable>: Equatable, Sendable {
    let files: [File]
    let tree: GitPathTree
    let byPath: [String: File]

    init(_ files: [File], path: KeyPath<File, String>) {
        self.files = files
        byPath = Dictionary(files.map { ($0[keyPath: path], $0) }, uniquingKeysWith: { _, last in last })
        tree = GitPathTree(paths: Array(byPath.keys))
    }

    func tags(prefix: String) -> Set<String> {
        Set(byPath.keys.map { prefix + $0 }).union(tree.folders.map { prefix + $0 })
    }

    func selectedFiles(in tags: Set<String>, prefix: String) -> [File] {
        let paths = Set(tags.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        if paths.count == 1, let path = paths.first, let file = byPath[path] { return [file] }
        return tree.filePaths(in: paths).compactMap { byPath[$0] }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.files == rhs.files }
}

extension GitChangedFiles where File == GitCommitFile {
    @concurrent static func load(in commit: GitCommit, at root: String) async -> Self {
        Self(await GitRepositoryLoader.files(in: commit, at: root), path: \.path)
    }
}

struct GitChangedFileTree<File: Equatable & Sendable, Row: View>: View {
    let changes: GitChangedFiles<File>
    var tagPrefix = ""
    let isSelected: (String) -> Bool
    @ViewBuilder let row: (File) -> Row
    @State private var collapsed: Set<String> = []

    var body: some View {
        ForEach(changes.tree.visibleRows(collapsing: collapsed)) { entry in
            let node = entry.node
            let indent = CGFloat(entry.depth) * 16
            let tag = tagPrefix + node.id
            if node.isDirectory {
                let isCollapsed = collapsed.contains(node.id)
                HStack(spacing: 5) {
                    Button {
                        if isCollapsed { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isCollapsed ? "Expand \(node.name)" : "Collapse \(node.name)")
                    GitFileIcon(name: node.name, isFolder: true)
                    Text(verbatim: node.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Spacer(minLength: 4)
                    Text(node.fileCount, format: .number)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .accessibilityLabel("\(node.fileCount) changed files")
                }
                .padding(.leading, indent)
                .contentShape(Rectangle())
                .themedListRow(tag, selected: isSelected(tag))
                .listRowSeparator(.hidden)
            } else if let file = changes.byPath[node.id] {
                row(file)
                    .padding(.leading, indent + 17)
                    .themedListRow(tag, selected: isSelected(tag))
                    .listRowSeparator(.hidden)
            }
        }
    }
}

struct GitFileIcon: View {
    let name: String
    var isFolder = false

    var body: some View {
        let type: UTType = isFolder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// A selected folder opens its contents in the detail pane. Choosing a file opens its diff or preview.
struct GitFolderContents: View {
    let folder: String
    let tree: GitPathTree
    let selectFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(String(folder.dropLast()), systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(10)
            Divider()
            List(tree.filePaths(in: [folder]), id: \.self) { path in
                Button {
                    selectFile(path)
                } label: {
                    HStack(spacing: 6) {
                        GitFileIcon(name: path)
                        Text(verbatim: String(path.dropFirst(folder.count))).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
