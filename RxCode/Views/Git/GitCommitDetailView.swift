import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Metadata, changed files, and the selected file's diff for one commit.
struct GitCommitDetailView: View {
    let commit: GitCommit
    let store: GitWorkflowStore
    @State private var files: [GitCommitFile] = []
    @State private var selectedFile: String?
    @State private var diffLines: [DiffLine] = []
    @State private var loadingFiles = true
    @State private var loadingDiff = false

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                summary
                Divider()
                fileList
            }
            .frame(minHeight: 200, idealHeight: 300)
            diffArea
                .frame(minHeight: 160, maxHeight: .infinity)
        }
        .task(id: commit.id) {
            loadingFiles = true
            files = await GitRepositoryLoader.files(in: commit, at: store.root)
            loadingFiles = false
            selectedFile = files.first?.path
        }
        .task(id: "\(commit.id)/\(selectedFile ?? "")") {
            guard let selectedFile, let file = files.first(where: { $0.path == selectedFile }) else {
                diffLines = []
                return
            }
            loadingDiff = true
            let raw = await GitRepositoryLoader.diff(of: file, in: commit, at: store.root)
            guard !Task.isCancelled else { return }
            diffLines = DiffComputation.parseUnifiedDiff(raw)
            loadingDiff = false
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
                ScrollView {
                    Text(commit.body)
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
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

    @ViewBuilder private var fileList: some View {
        if loadingFiles {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            ContentUnavailableView("No file changes", systemImage: "doc", description: Text(commit.isMerge ? "Merge commits list changes against their first parent." : ""))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(files, selection: $selectedFile) { file in
                GitCommitFileRow(file: file).tag(file.path)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder private var diffArea: some View {
        if loadingDiff && diffLines.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diffLines.isEmpty {
            ContentUnavailableView(selectedFile == nil ? "Select a file" : "No textual changes", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffView(lines: diffLines, display: .scroll)
        }
    }
}

struct GitCommitFileRow: View {
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
