import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// Compact pill displayed directly above the chat input bar whenever the
/// current thread has edited files. Tapping it opens the Review inspector on
/// the "This thread" tab. Hidden mid-turn so it doesn't flicker as edits land.
struct ThreadDiffBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge
    @State private var isHovered: Bool = false
    @State private var stat: (added: Int, removed: Int) = (0, 0)

    private var summaries: [FileEditSummary] {
        _ = appState.threadFileEditsRevision
        return appState.threadFileEdits(in: windowState)
    }

    private var statKey: String {
        "\(windowState.currentSessionId ?? windowState.newSessionKey)-\(appState.threadFileEditsRevision)"
    }

    var body: some View {
        let summaries = summaries
        if !summaries.isEmpty, !chatBridge.isStreaming {
            content(fileCount: summaries.count)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: statKey) {
                    stat = await Self.computeStat(summaries)
                }
        }
    }

    private func content(fileCount: Int) -> some View {
        let fileText = fileCount == 1 ? "1 file changed" : "\(fileCount) files changed"
        return Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "plusminus.circle")
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)

                Text(fileText)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                HStack(spacing: 6) {
                    if stat.added > 0 {
                        Text("+\(stat.added)")
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                    if stat.removed > 0 {
                        Text("−\(stat.removed)")
                            .foregroundStyle(ClaudeTheme.statusError)
                    }
                }
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))

                Spacer(minLength: 8)

                Text("View Diff")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.surfaceSecondary, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .fill(ClaudeTheme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .strokeBorder(ClaudeTheme.borderSubtle.opacity(isHovered ? 1 : 0.6), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Open this thread's changes")
    }

    private func open() {
        windowState.inspectorMode = .review
        windowState.inspectorReviewTab = .thisThread
        appState.showRightSidebar = true
    }

    /// Mirrors `ThisThreadFileRow`: prefer the snapshot-pair count, falling
    /// back to hunk line counts when the snapshot collapsed to zero.
    private static func computeStat(_ summaries: [FileEditSummary]) async -> (added: Int, removed: Int) {
        await Task.detached(priority: .utility) {
            var added = 0
            var removed = 0
            for summary in summaries {
                if let modified = summary.modifiedContent {
                    let stat = ChangeDiffView.snapshotStat(
                        original: summary.originalContent ?? "", modified: modified)
                    if stat.added > 0 || stat.removed > 0 {
                        added += stat.added
                        removed += stat.removed
                        continue
                    }
                }
                for hunk in summary.hunks {
                    if !hunk.newString.isEmpty { added += hunk.newString.components(separatedBy: "\n").count }
                    if !hunk.oldString.isEmpty { removed += hunk.oldString.components(separatedBy: "\n").count }
                }
            }
            return (added, removed)
        }.value
    }
}
