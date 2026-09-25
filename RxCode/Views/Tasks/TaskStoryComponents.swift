import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Agent label

extension AppState {
    /// "Opus · high" style summary of a task's agent assignment.
    func taskAgentLabel(_ agent: TaskAgentConfig) -> String {
        var parts: [String] = []
        if let model = agent.model, !model.isEmpty {
            parts.append(modelDisplayLabel(model, provider: agent.provider ?? .claudeCode))
        } else if let provider = agent.provider {
            parts.append(provider.displayNameText)
        }
        if let effort = agent.effort, !effort.isEmpty {
            parts.append(effort)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Story identity

extension ProjectStory {
    /// A stable per-story color, so a story and its tasks read as one group
    /// across board columns. Derived from the id rather than stored, so it
    /// needs no persistence and stays the same across launches.
    var tint: Color {
        let palette: [Color] = [
            ClaudeTheme.accent, ClaudeTheme.statusRunning, .purple, ClaudeTheme.statusSuccess,
            .pink, .teal, .indigo, ClaudeTheme.statusWarning,
        ]
        let seed = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return palette[seed % palette.count]
    }
}

// MARK: - Story hover

/// The story under the pointer anywhere on the board, shared by every column
/// so a story and its tasks light up together.
///
/// A reference in the environment rather than a binding threaded through each
/// card: hover changes then only update the views that read `storyId` in their
/// body (the card chrome), instead of rebuilding every card's whole body on
/// each pointer move.
@Observable
final class TaskBoardHoverState {
    var storyId: UUID?

    /// Hover handler for a view that represents `storyId`: claims the
    /// highlight on enter, and releases it on exit unless another view
    /// already took it over.
    func update(hovering: Bool, storyId: UUID) {
        if hovering {
            if self.storyId != storyId { self.storyId = storyId }
        } else if self.storyId == storyId {
            self.storyId = nil
        }
    }
}

/// The story a task belongs to, as a tinted chip on the task card. Tapping
/// shows a popover with the story's name and progress; hovering highlights the
/// story and its sibling tasks on the board.
struct TaskStoryChip: View {
    let story: ProjectStory
    let progress: StoryProgress
    let column: TaskColumn

    @Environment(TaskBoardHoverState.self) private var hover: TaskBoardHoverState?
    @State private var showsPopover = false

    var body: some View {
        // A button, not a tap gesture, so the tap wins over the card's own
        // tap-to-edit gesture.
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(story.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(story.tint.opacity(showsPopover ? 0.26 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show story")
        .onHover { hover?.update(hovering: $0, storyId: story.id) }
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(story.tint)
                    Text("Story")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer(minLength: 0)
                    TaskStatusIcon(column: column, size: 11)
                }
                Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                StoryProgressBar(progress: progress)
            }
            .padding(12)
            .frame(width: 240)
        }
    }
}

// MARK: - Task summary

/// Two-line preview of what a task is about, with an icon that opens the full
/// text in a popover. Prefers the generated summary of the thread the agent
/// ran in (what was actually done); falls back to the task's description.
struct TaskSummaryPreview: View {
    @Environment(AppState.self) private var appState

    let task: ProjectTask

    @State private var showsFull = false

    /// `stripMarkdown` results by source text. Cards re-render on board edits
    /// and agent activity far more often than their text changes, and the
    /// regex passes showed up while scrolling the board.
    private static let strippedText: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    private static func preview(of text: String) -> String {
        let key = text as NSString
        if let cached = strippedText.object(forKey: key) { return cached as String }
        let stripped = stripMarkdown(text)
        strippedText.setObject(stripped as NSString, forKey: key)
        return stripped
    }

    private var content: (title: LocalizedStringKey, text: String)? {
        if let key = task.sessionKey {
            // Re-read when a thread summary is regenerated.
            _ = appState.threadSummaryRevision
            let sessionId = appState.resolveCurrentSessionId(key)
            let summary = appState.threadStore.threadSummaryItem(sessionId: sessionId)?.summary
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty { return ("Agent Summary", summary) }
        }
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? nil : ("Description", details)
    }

    var body: some View {
        if let content {
            HStack(alignment: .top, spacing: 6) {
                // Stripped, not rendered: descriptions are Markdown, and two
                // truncated lines of a card have no room for block layout —
                // raw syntax would just eat the preview.
                Text(Self.preview(of: content.text))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showsFull.toggle()
                } label: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                        .foregroundStyle(showsFull ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(content.title))
                .popover(isPresented: $showsFull, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(content.title)
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        ScrollView {
                            MarkdownContentView(text: content.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 360)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 340)
                }
            }
        }
    }
}
