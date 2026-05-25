import SwiftUI
#if os(macOS)
import RxCodeCore
import DiffView

public struct FileDiffView: View {
    public let filePath: String
    public let fileName: String
    public let editHunks: [PreviewFile.EditHunk]
    public let gitDiffMode: PreviewFile.GitDiffMode?
    public let showFullFileDiff: Bool
    /// Pre-edit snapshot — "before" side of the snapshot-pair diff.
    public let originalContent: String?
    /// Post-edit snapshot captured after this thread's most recent edit
    /// tool_result. When non-nil alongside `showFullFileDiff`, the view diffs
    /// `originalContent` against this snapshot directly with no disk read,
    /// giving a thread-isolated diff that doesn't pick up external concurrent
    /// edits. Falls back to original-vs-disk when nil (legacy rows).
    public let modifiedContent: String?
    @Environment(WindowState.self) private var windowState
    @State private var diffLines: [DiffLine] = []
    @State private var isLoading = true
    @State private var isCopied = false

    public init(
        filePath: String,
        fileName: String,
        editHunks: [PreviewFile.EditHunk] = [],
        gitDiffMode: PreviewFile.GitDiffMode? = nil,
        showFullFileDiff: Bool = false,
        originalContent: String? = nil,
        modifiedContent: String? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.editHunks = editHunks
        self.gitDiffMode = gitDiffMode
        self.showFullFileDiff = showFullFileDiff
        self.originalContent = originalContent
        self.modifiedContent = modifiedContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            contentArea
        }
        .background(ClaudeTheme.background)
        .background {
            Button("") { windowState.diffFile = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
        .task(id: filePath) { await loadDiff() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: ClaudeTheme.messageSize(13)))
                .foregroundStyle(ClaudeTheme.accent)

            Text(fileName)
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .semibold, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("Diff", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(ClaudeTheme.surfaceSecondary, in: Capsule())

            if !diffLines.isEmpty {
                Button {
                    let raw = diffLines.map(\.text).joined(separator: "\n")
                    copyToClipboard(raw, feedback: $isCopied)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(isCopied ? ClaudeTheme.statusSuccess : ClaudeTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(isCopied ? "Copied" : "Copy")
            }

            Button { windowState.diffFile = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(ClaudeTheme.surfaceSecondary, in: Circle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClaudeTheme.surfacePrimary)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(ClaudeTheme.codeBackground)
        } else if diffLines.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: ClaudeTheme.messageSize(24)))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                Text("No changes", bundle: .module)
                    .font(.system(size: ClaudeTheme.messageSize(13)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(ClaudeTheme.codeBackground)
        } else {
            DiffView(lines: diffLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Diff Sources

    private func loadDiff() async {
        isLoading = true
        defer { isLoading = false }

        // Snapshot-pair path: both originalContent and modifiedContent were
        // captured from disk at the right moments (pre-first-edit and
        // post-each-edit). Diff them directly — no view-time disk read, no
        // contamination from external concurrent edits on the same file.
        if showFullFileDiff, let modified = modifiedContent {
            let original = originalContent ?? ""
            let lines = await Task.detached(priority: .userInitiated) {
                DiffComputation.buildSnapshotDiffLines(original: original, current: modified)
            }.value
            if !lines.isEmpty {
                diffLines = lines
                return
            }
            // Snapshot pair collapsed (e.g. original lost its capture race).
            // Fall through to the legacy / hunk paths so a real edit still
            // shows something instead of an empty "no changes" state.
        }

        // Legacy fallback for rows persisted before modifiedContent existed:
        // diff the original snapshot against the current on-disk content.
        if showFullFileDiff, let original = originalContent {
            let path = filePath
            diffLines = await Task.detached(priority: .userInitiated) {
                let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                return DiffComputation.buildSnapshotDiffLines(original: original, current: current)
            }.value
            return
        }

        if !editHunks.isEmpty {
            let hunks = editHunks
            let path = filePath
            if showFullFileDiff,
               let fullFileLines = await Task.detached(priority: .userInitiated, operation: { () -> [DiffLine]? in
                   guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                       return nil
                   }
                   return DiffComputation.buildFullFileEditDiffLines(currentContent: contents, hunks: hunks)
               }).value {
                diffLines = fullFileLines
                return
            }

            diffLines = await Task.detached(priority: .userInitiated) {
                DiffComputation.buildEditDiffLines(from: hunks)
            }.value
            return
        }

        let workDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        if case .untracked = gitDiffMode {
            let contents = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
            let hunks = [PreviewFile.EditHunk(oldString: "", newString: contents)]
            diffLines = await Task.detached(priority: .userInitiated) {
                DiffComputation.buildEditDiffLines(from: hunks)
            }.value
            return
        }
        let raw: String
        switch gitDiffMode {
        case .unstaged:
            raw = await GitHelper.run(["diff", "--", filePath], at: workDir) ?? ""
        case .staged:
            raw = await GitHelper.run(["diff", "--cached", "--", filePath], at: workDir) ?? ""
        case .untracked:
            raw = ""
        case .none:
            if let r1 = await GitHelper.run(["diff", "HEAD", "--", filePath], at: workDir) {
                raw = r1
            } else if let r2 = await GitHelper.run(["diff", "--", filePath], at: workDir) {
                raw = r2
            } else {
                raw = await GitHelper.run(["show", "HEAD", "--", filePath], at: workDir) ?? ""
            }
        }
        diffLines = await Task.detached(priority: .userInitiated) {
            DiffComputation.parseUnifiedDiff(raw)
        }.value
    }
}
#endif
