import AppKit
import SwiftUI
import RxCodeCore

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
        }
    }
}

struct ThisThreadFileRow: View {
    let summary: FileEditSummary
    @Environment(WindowState.self) private var windowState
    @State private var isHovering = false

    private var additions: Int {
        summary.hunks.reduce(0) { count, hunk in
            count + nonEmptyLineCount(hunk.newString)
        }
    }

    private var deletions: Int {
        summary.hunks.reduce(0) { count, hunk in
            count + nonEmptyLineCount(hunk.oldString)
        }
    }

    private var parentDirectory: String {
        let parent = (summary.path as NSString).deletingLastPathComponent
        return parent
    }

    var body: some View {
        Button {
            windowState.diffFile = PreviewFile(
                path: summary.path,
                name: summary.name,
                editHunks: summary.hunks,
                showFullFileDiff: true,
                originalContent: summary.originalContent
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: summary.containsWrite ? "doc.badge.plus" : "pencil")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.statusWarning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
    }

    private func nonEmptyLineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return s.components(separatedBy: "\n").count
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
