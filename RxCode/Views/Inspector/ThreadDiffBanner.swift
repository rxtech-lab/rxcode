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
    @State private var changes: LoadedChanges?
    @State private var presentedThread: PresentedThread?

    private struct PresentedThread: Identifiable {
        let id: String
    }

    private struct LoadedChanges {
        let sessionId: String
        let fileCount: Int
        var stat: (added: Int, removed: Int) = (0, 0)
    }

    private var loadID: ThreadFileEditsLoadID {
        appState.threadFileEditsLoadID(sessionId: sessionId ?? windowState.currentSessionId ?? windowState.newSessionKey)
    }

    var body: some View {
        let key = loadID
        let visibleChanges = changes?.sessionId == key.sessionId ? changes : nil
        Group {
            if let visibleChanges, visibleChanges.fileCount > 0 || isCompact {
                content(fileCount: visibleChanges.fileCount, stat: visibleChanges.stat)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $presentedThread) { thread in
            ThisThreadDiffView(sessionId: thread.id)
        }
        .task(id: key) {
            let summaries = await appState.loadThreadDiffPreview(key)
            guard !Task.isCancelled, loadID == key else { return }
            changes = LoadedChanges(
                sessionId: key.sessionId,
                fileCount: summaries.count,
                stat: visibleChanges?.stat ?? (0, 0)
            )
            guard !summaries.isEmpty else { return }
            let stat = await Self.computeStat(summaries)
            guard !Task.isCancelled, loadID == key else { return }
            changes?.stat = stat
        }
    }

    private func content(fileCount: Int, stat: (added: Int, removed: Int)) -> some View {
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
        presentedThread = PresentedThread(id: loadID.sessionId)
    }

    /// Mirrors `ThisThreadFileRow`: computes thread-isolated `+/-` stats via
    /// `DiffComputation.threadEditStat`, isolating hunks when external
    /// interleaving occurred.
    static func computeStat(_ summaries: [FileEditSummary]) async -> (added: Int, removed: Int) {
        await Task.detached(priority: .utility) {
            var added = 0
            var removed = 0
            for summary in summaries {
                if summary.modifiedContent != nil || summary.hasExternalInterleaving {
                    let stat = DiffComputation.threadEditStat(
                        originalContent: summary.originalContent,
                        modifiedContent: summary.modifiedContent,
                        hunks: summary.hunks,
                        preferHunks: summary.hasExternalInterleaving
                    )
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
