import RxCodeCore
import SwiftUI

// MARK: - Sheet payload

/// What the board's sheet is editing. `ProjectTask` and `ProjectStory` are both
/// `Identifiable`, but `.sheet(item:)` needs one type, so they're unified here.
enum TaskBoardSheet: Identifiable {
    case task(ProjectTask)
    case story(ProjectStory)

    var id: String {
        switch self {
        case .task(let task): return "task-\(task.id.uuidString)"
        case .story(let story): return "story-\(story.id.uuidString)"
        }
    }
}

// MARK: - Status styling

extension TaskStatus {
    /// Column accent, using the existing status tokens so the board matches the
    /// rest of the app's state colors. Ordered like the GitHub Projects palette:
    /// ready (blue), in progress (orange), in review (purple), done (green).
    var tint: Color {
        switch self {
        case .pending: return ClaudeTheme.statusRunning
        case .inProgress: return ClaudeTheme.statusWarning
        case .pendingReview: return .purple
        case .done: return ClaudeTheme.statusSuccess
        }
    }

    /// The one-line column description under a board column header.
    var columnDescription: LocalizedStringResource {
        switch self {
        case .pending: return "This item hasn't been started"
        case .inProgress: return "This is actively being worked on"
        case .pendingReview: return "This item is in review"
        case .done: return "This has been completed"
        }
    }

    /// Hollow ring for open states, filled check once done — the issue-state
    /// glyphs GitHub uses on project cards.
    var ringSymbol: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .pendingReview: return "eye.circle"
        case .done: return "checkmark.circle.fill"
        }
    }
}

struct TaskStatusIcon: View {
    let status: TaskStatus
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: status.ringSymbol)
            .font(.system(size: ClaudeTheme.size(size), weight: .semibold))
            .foregroundStyle(status.tint)
            .help(Text(status.displayName))
    }
}

/// The rounded count bubble beside a column or section title.
struct TaskCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(ClaudeTheme.surfaceTertiary))
    }
}

/// Outlined label pill (version, tag, story) matching GitHub's field chips.
struct TaskPill: View {
    let text: String
    var icon: String?
    var tint: Color = ClaudeTheme.textSecondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
            }
            Text(text)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// "5 / 6  ▰▰▰▰▱  83%" — rolled-up story progress.
struct StoryProgressBar: View {
    let progress: StoryProgress

    var body: some View {
        HStack(spacing: 8) {
            Text("\(progress.done) / \(progress.total)")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .monospacedDigit()

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ClaudeTheme.accent.opacity(0.18))
                    Capsule()
                        .fill(ClaudeTheme.accent)
                        .frame(width: proxy.size.width * progress.fraction)
                }
            }
            .frame(height: 6)

            Text("\(progress.percent)%")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .monospacedDigit()
        }
    }
}

/// GitHub's "Filter by keyword" bar.
struct TaskFilterField: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "Filter by keyword"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: ClaudeTheme.size(13)))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.inputBorder, lineWidth: 1)
        )
    }
}

/// Header filter chip. Mirrors the composer/toolbar chip styling in
/// `ChatToolbarComponents` so the board header reads as part of the same app.
struct TaskBoardChipLabel: View {
    let icon: String
    let title: String
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            Text(title)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
        }
        .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(isActive ? ClaudeTheme.accent.opacity(0.10) : ClaudeTheme.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Shared menus

/// Right-click actions for a task, shared by board cards, table rows and the
/// overview list so every surface offers the same verbs.
struct TaskContextMenuItems: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let task: ProjectTask
    let onEdit: () -> Void
    /// Called before revealing the chat, so a sheet hosting this menu can
    /// dismiss itself instead of staying over the thread.
    var onOpenChat: (() -> Void)?

    var body: some View {
        Button("Edit…", action: onEdit)

        if appState.canOpenChat(for: task) {
            Button("Open Chat") {
                onOpenChat?()
                appState.openChat(for: task, in: windowState)
            }
        }

        if task.agent.isAssigned, task.status != .inProgress {
            Button("Run with Agent") {
                appState.moveTask(task, to: .inProgress)
            }
        }

        Divider()

        Menu("Move To") {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button(status.displayNameText) {
                    appState.moveTask(task, to: status)
                }
                .disabled(status == task.status)
            }
        }
        .disabled(task.isStatusLocked)

        Divider()

        Button("Delete", role: .destructive) {
            appState.deleteTask(task)
        }
    }
}

struct StoryContextMenuItems: View {
    @Environment(AppState.self) private var appState

    let story: ProjectStory
    let onEdit: () -> Void

    var body: some View {
        Button("Edit…", action: onEdit)
        Divider()
        Button("Delete", role: .destructive) {
            appState.deleteStory(story)
        }
    }
}

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

/// The story a task belongs to, as a tinted chip on the task card. Tapping
/// shows a popover with the story's name and progress; hovering highlights the
/// story and its sibling tasks on the board.
struct TaskStoryChip: View {
    let story: ProjectStory
    let progress: StoryProgress
    let status: TaskStatus
    @Binding var hoveredStoryId: UUID?

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
        .onHover { hovering in
            if hovering {
                hoveredStoryId = story.id
            } else if hoveredStoryId == story.id {
                hoveredStoryId = nil
            }
        }
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(story.tint)
                    Text("Story")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer(minLength: 0)
                    TaskStatusIcon(status: status, size: 11)
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
                Text(content.text)
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
                            Text(content.text)
                                .font(.system(size: ClaudeTheme.size(12)))
                                .foregroundStyle(ClaudeTheme.textPrimary)
                                .textSelection(.enabled)
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
