import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// File-change summary for the current chat or a task's thread. Tapping it
/// opens that thread's changes, including while a turn is streaming.
struct ThreadDiffBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    var sessionId: String? = nil
    var isCompact = false
    var onOpen: (() -> Void)? = nil
    @State private var isHovered: Bool = false
    @State private var stat: (added: Int, removed: Int) = (0, 0)

    private var summaries: [FileEditSummary] {
        _ = appState.threadFileEditsRevision
        if let sessionId {
            return appState.threadFileEdits(sessionId: sessionId)
        }
        return appState.threadFileEdits(in: windowState)
    }

    private var statKey: String {
        "\(sessionId ?? windowState.currentSessionId ?? windowState.newSessionKey)-\(appState.threadFileEditsRevision)"
    }

    var body: some View {
        let summaries = summaries
        if !summaries.isEmpty || isCompact {
            content(fileCount: summaries.count)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: statKey) {
                    stat = await Self.computeStat(summaries)
                }
        }
    }

    private func content(fileCount: Int) -> some View {
        let fileText = fileCount == 0 ? String(localized: "No changes")
            : fileCount == 1 ? "1 file changed" : "\(fileCount) files changed"
        return Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: fileCount == 0 ? "checkmark.circle" : "plusminus.circle")
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)

                Text(fileText)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .contentTransition(.numericText(value: Double(fileCount)))
                    .animation(.easeInOut(duration: 0.25), value: fileCount)

                if fileCount > 0 {
                    HStack(spacing: 6) {
                        if stat.added > 0 {
                            Text("+\(stat.added)")
                                .foregroundStyle(ClaudeTheme.statusSuccess)
                                .contentTransition(.numericText(value: Double(stat.added)))
                        }
                        if stat.removed > 0 {
                            Text("−\(stat.removed)")
                                .foregroundStyle(ClaudeTheme.statusError)
                                .contentTransition(.numericText(value: Double(stat.removed)))
                        }
                    }
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))
                    .animation(.easeInOut(duration: 0.25), value: stat.added)
                    .animation(.easeInOut(duration: 0.25), value: stat.removed)
                }

                if !isCompact {
                    Spacer(minLength: 8)

                    Text("View Diff")
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(ClaudeTheme.surfaceSecondary, in: Capsule())
                }
            }
            .padding(.horizontal, isCompact ? 10 : 14)
            .padding(.vertical, isCompact ? 5 : 8)
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
        .padding(.horizontal, isCompact ? 0 : 16)
        .padding(.bottom, isCompact ? 0 : 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(isCompact ? String(localized: "Open Chat") : String(localized: "Open this thread's changes"))
    }

    private func open() {
        if let onOpen {
            onOpen()
            return
        }
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
