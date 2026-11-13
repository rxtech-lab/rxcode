import AppKit
import SwiftUI
import RxCodeCore
import RxCodeChatKit

// MARK: - This Thread

struct ThisThreadDiffView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var summaries: [FileEditSummary] {
        _ = appState.threadFileEditsRevision
        return appState.threadFileEdits(in: windowState)
    }

    var body: some View {
        let summaries = summaries
        if summaries.isEmpty {
            InspectorEmptyState(
                title: "No file changes yet",
                message: "This thread has not edited any files."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(summaries) { summary in
                        ThisThreadFileRow(summary: summary)
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
    }
}

struct ThisThreadFileRow: View {
    let summary: FileEditSummary
    @Environment(WindowState.self) private var windowState
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
        Button {
            windowState.diffFile = PreviewFile(
                path: summary.path,
                name: summary.name,
                editHunks: summary.hunks,
                showFullFileDiff: true,
                originalContent: summary.originalContent,
                modifiedContent: summary.modifiedContent,
                preferHunks: summary.hasExternalInterleaving
            )
        } label: {
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

struct BranchInfoView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            VStack(spacing: 0) {
                GitStatusView(projectPath: project.path)
                Spacer()
            }
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to inspect its branch.")
        }
    }
}
