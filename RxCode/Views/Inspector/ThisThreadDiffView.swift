import AppKit
import SwiftUI
import RxCodeCore
import RxCodeChatKit

// MARK: - This Thread

struct ThisThreadDiffView: View {
    let sessionId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var loaded: (sessionId: String, summaries: [FileEditSummary])?
    @State private var selectedFile: FileEditSummary?

    private var loadID: ThreadFileEditsLoadID {
        appState.threadFileEditsLoadID(sessionId: sessionId)
    }

    var body: some View {
        let key = loadID
        NavigationStack {
            ThreadChangeList(summaries: loaded?.sessionId == key.sessionId ? loaded?.summaries : nil) {
                selectedFile = $0
            }
            .navigationTitle("This Thread’s Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedFile != nil },
                set: { if !$0 { selectedFile = nil } }
            )) {
                if let file = selectedFile {
                    FileDiffView(
                        filePath: file.path,
                        fileName: file.name,
                        editHunks: file.hunks,
                        showFullFileDiff: true,
                        originalContent: file.originalContent,
                        modifiedContent: file.modifiedContent,
                        preferHunks: file.hasExternalInterleaving,
                        onClose: { selectedFile = nil }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 560, idealHeight: 760)
        .task(id: key) {
            let summaries = await appState.loadThreadDiffPreview(key)
            guard !Task.isCancelled, loadID == key else { return }
            loaded = (key.sessionId, summaries)
        }
    }
}

struct ThreadChangeList: View {
    let summaries: [FileEditSummary]?
    let showDiff: (FileEditSummary) -> Void
    var showPreview: ((FileEditSummary) -> Void)? = nil

    var body: some View {
        Group {
            if let summaries {
                if summaries.isEmpty {
                    InspectorEmptyState(
                        title: "No file changes yet",
                        message: "This thread has not edited any files."
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(summaries) { summary in
                                ThisThreadFileRow(
                                    summary: summary,
                                    showDiff: { showDiff(summary) },
                                    showPreview: showPreview.map { action in { action(summary) } }
                                )
                            }
                        }
                        .padding(12)
                    }
                    .onAppear {
                        AnalyticsService.shared.log(.diffViewOpened, parameters: [
                            "surface": "this_thread",
                            "file_count": summaries.count,
                        ])
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThisThreadFileRow: View {
    let summary: FileEditSummary
    let showDiff: () -> Void
    var showPreview: (() -> Void)? = nil
    @State private var isHovering = false
    @State private var snapshotStat: (added: Int, removed: Int)?

    private var additions: Int {
        if let stat = snapshotStat, stat.added > 0 || stat.removed > 0 {
            return stat.added
        }
        return summary.hunks.reduce(0) { count, hunk in
            count + nonEmptyLineCount(hunk.newString)
        }
    }

    private var deletions: Int {
        if let stat = snapshotStat, stat.added > 0 || stat.removed > 0 {
            return stat.removed
        }
        return summary.hunks.reduce(0) { count, hunk in
            count + nonEmptyLineCount(hunk.oldString)
        }
    }

    private var parentDirectory: String {
        (summary.path as NSString).deletingLastPathComponent
    }

    private var iconName: String {
        if summary.isDeleted { return "trash" }
        if summary.containsWrite { return "doc.badge.plus" }
        return "pencil"
    }

    private var iconColor: Color {
        if summary.isDeleted { return ClaudeTheme.statusError }
        return ClaudeTheme.statusWarning
    }

    var body: some View {
        Button(action: showDiff) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(summary.name)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if summary.isAmbiguous {
                            Text("Concurrent")
                                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                                .foregroundStyle(ClaudeTheme.statusWarning)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(ClaudeTheme.statusWarning.opacity(0.14), in: Capsule())
                                .help("Modified while another thread also ran a mutating command in this workspace.")
                        }
                    }
                    if !parentDirectory.isEmpty {
                        Text(parentDirectory)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                    if deletions > 0 {
                        Text("−\(deletions)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.statusError)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(isHovering ? ClaudeTheme.surfaceSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Show Diff", systemImage: "arrow.left.arrow.right") { showDiff() }
            if let showPreview {
                Button("Show Preview", systemImage: "eye") { showPreview() }
                    .disabled(summary.isDeleted || !FileManager.default.fileExists(atPath: summary.path))
            }
            Divider()
            GitFileSystemContextMenuItems(paths: [summary.path])
        }
        .task(id: "\(summary.modifiedContent ?? "nil")-\(summary.hasExternalInterleaving)-\(summary.hunks.count)") {
            await computeSnapshotStat()
        }
    }

    private func nonEmptyLineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return s.components(separatedBy: "\n").count
    }

    private func computeSnapshotStat() async {
        guard summary.modifiedContent != nil || summary.hasExternalInterleaving else {
            snapshotStat = nil
            return
        }
        let original = summary.originalContent
        let modified = summary.modifiedContent
        let hunks = summary.hunks
        let preferHunks = summary.hasExternalInterleaving
        snapshotStat = await Task.detached(priority: .userInitiated) {
            DiffComputation.threadEditStat(
                originalContent: original,
                modifiedContent: modified,
                hunks: hunks,
                preferHunks: preferHunks
            )
        }.value
    }
}
