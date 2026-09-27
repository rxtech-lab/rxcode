import RxCodeCore
import SwiftUI

/// One task card on the board, laid out like a GitHub Projects item card:
/// a context line, the title, then field pills.
///
/// The body deliberately reads no `AppState` itself: agent activity, chat
/// availability and the agent label live in small child views, so session and
/// agent updates re-render those children instead of every card on the board.
struct TaskCardView: View {
    @Environment(AppState.self) private var appState

    let task: ProjectTask
    let board: TaskBoard
    /// The task's story progress and column, precomputed once for the whole
    /// board by `TaskBoard.storyRollups()`. `nil` falls back to computing it
    /// here.
    var storyRollup: StoryRollup?
    let onOpen: () -> Void
    @State private var pendingDeletion: TaskBoardSheet?
    @State private var showsAttentionReason = false

    private var story: ProjectStory? { board.story(id: task.storyId) }

    var body: some View {
        let story = story
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                TaskStatusIcon(status: task.status, board: board, size: 11)
                if let story {
                    let rollup = storyRollup ?? StoryRollup(
                        progress: board.progress(for: story),
                        status: board.rolledUpStatus(for: story)
                    )
                    TaskStoryChip(
                        story: story,
                        progress: rollup.progress,
                        column: board.column(for: rollup.status)
                    )
                } else {
                    Text("Task")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                Spacer(minLength: 0)
                if let reason = task.attentionReason {
                    Button {
                        showsAttentionReason.toggle()
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.statusWarning)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show full error message")
                    .accessibilityLabel("Show full error message")
                    .popover(isPresented: $showsAttentionReason, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Needs Attention")
                                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                            ScrollView {
                                Text(verbatim: reason)
                                    .font(.system(size: ClaudeTheme.size(12)))
                                    .foregroundStyle(ClaudeTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 360)
                        }
                        .padding(14)
                        .frame(width: 420)
                    }
                }
                TaskCardActivityControls(task: task)
            }

            Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(task.parentTaskIds, id: \.self) { parentID in
                if let parent = board.tasks.first(where: { $0.id == parentID }) {
                    TaskCardStartsAfterRow(parent: parent, board: board)
                } else {
                    TaskCardCrossProjectStartsAfterRow(parentID: parentID)
                }
            }

            TaskSummaryPreview(task: task)

            TaskVerifyingIndicator(taskId: task.id)

            if let reason = task.attentionReason {
                Text(reason)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusWarning)
                    .lineLimit(2)
                    .help(reason)
            }

            if hasPills {
                FlowLayout(spacing: 4) {
                    TaskClassificationPills(task: task, board: board)
                    if task.agent.planMode {
                        TaskPill(text: String(localized: "Plan"), icon: "eye", tint: ClaudeTheme.statusWarning)
                    }
                    if !task.attachments.isEmpty {
                        TaskPill(text: "\(task.attachments.count)", icon: "paperclip")
                    }
                }
            }

            if task.agent.isAssigned {
                ClaudeThemeDivider()
                TaskCardModelRow(agent: task.agent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TaskCardChrome(
            stripe: story?.tint,
            storyId: task.storyId,
            storyTint: story?.tint,
            fixedHighlight: task.attentionReason != nil ? ClaudeTheme.statusWarning : nil
        ))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            TaskContextMenuItems(task: task, onEdit: onOpen, onDelete: {
                pendingDeletion = .task(task)
            })
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .task(let task, _) = candidate { appState.deleteTask(task) }
        }
    }

    private var hasPills: Bool {
        TaskClassificationPills(task: task, board: board).hasContent
            || task.agent.planMode || !task.attachments.isEmpty
    }
}

/// A story on the board, sitting in the column its tasks roll up to, with the
/// GitHub parent-issue progress bar.
struct StoryCardView: View {
    @Environment(AppState.self) private var appState

    let story: ProjectStory
    let progress: StoryProgress
    var board: TaskBoard?
    /// The story's rolled-up status, shown as a chip when the card sits
    /// outside the board columns.
    var column: TaskColumn?
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onOpen: () -> Void
    /// Opens the task form on a draft parented to this story.
    let onNewTask: (ProjectTask) -> Void
    @Environment(TaskBoardHoverState.self) private var hover: TaskBoardHoverState?
    @State private var pendingDeletion: TaskBoardSheet?

    private var canCollapse: Bool {
        progress.total > 0 && progress.done == progress.total
    }

    private var sharedHelp: String {
        let names = appState.projects.filter { story.linkedProjectIds.contains($0.id) }.map(\.name)
        return String(localized: "Shared with \(names.joined(separator: ", "))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(story.tint)
                Text("Story")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                if let column {
                    HStack(spacing: 3) {
                        TaskStatusIcon(column: column, size: 9)
                        Text(column.name)
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(column.tint.opacity(0.12)))
                    .accessibilityElement(children: .combine)
                }
                if story.isShared {
                    Image(systemName: "link")
                        .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .help(sharedHelp)
                        .accessibilityLabel(sharedHelp)
                }
                Spacer(minLength: 0)
                if let board {
                    StoryRunningIndicator(story: story, board: board)
                }
                if progress.total > 0 {
                    Text("\(progress.total) tasks")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .help("Hover to highlight this story's tasks")
                }
                if canCollapse {
                    Button(action: onToggleCollapse) {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Show tasks" : "Hide tasks")
                    .accessibilityLabel(isCollapsed ? "Show tasks" : "Hide tasks")
                    .accessibilityIdentifier("story-toggle-tasks-\(story.id.uuidString)")
                }
            }

            Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let board {
                let pills = TaskClassificationPills(story: story, board: board)
                if pills.hasContent {
                    FlowLayout(spacing: 4) { pills }
                }
            }

            if let board {
                StoryProgressBar(progress: progress, board: board)
            } else {
                StoryProgressBar(progress: progress)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TaskCardChrome(stripe: story.tint, storyId: story.id, storyTint: story.tint))
        .onHover { hover?.update(hovering: $0, storyId: story.id) }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            StoryContextMenuItems(story: story, onEdit: onOpen, onDelete: {
                pendingDeletion = .story(story)
            }, onNewTask: onNewTask)
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .story(let story, _) = candidate { appState.deleteStory(story) }
        }
    }
}

/// Shared card background, border and hover lift. `stripe` is the owning
/// story's color along the leading edge. While a story is hovered anywhere on
/// the board, cards of that story (`storyId`) are outlined in `storyTint` and
/// every other card fades; `fixedHighlight` outlines the card regardless.
///
/// This is the only part of a card that reads the board's hover state, so a
/// hover change re-evaluates this modifier rather than the card's content.
private struct TaskCardChrome: ViewModifier {
    var stripe: Color?
    var storyId: UUID?
    var storyTint: Color?
    var fixedHighlight: Color?

    @Environment(TaskBoardHoverState.self) private var hover: TaskBoardHoverState?
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let hoveredStoryId = hover?.storyId
        let highlight = fixedHighlight
            ?? (storyId != nil && hoveredStoryId == storyId ? storyTint : nil)
        let isDimmed = hoveredStoryId != nil && hoveredStoryId != storyId
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        content
            .padding(.leading, stripe == nil ? 0 : 3)
            .background(shape.fill(ClaudeTheme.surfaceElevated))
            .overlay(alignment: .leading) {
                if let stripe {
                    Rectangle()
                        .fill(stripe)
                        .frame(width: 3)
                }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    highlight ?? (isHovering ? ClaudeTheme.border : ClaudeTheme.borderSubtle),
                    lineWidth: highlight == nil ? 1 : 1.5
                )
            )
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0), radius: 6, y: 3)
            .offset(y: isHovering && !reduceMotion ? -1 : 0)
            .opacity(isDimmed ? 0.45 : 1)
            .animation(.easeOut(duration: 0.15), value: isDimmed)
            .animation(.easeOut(duration: 0.15), value: highlight == nil)
            .taskBoardAnimation(TaskBoardMotion.feedback, value: isHovering)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

// MARK: - AppState-backed card parts

/// The running spinner and Open Chat button in a task card's header. Kept out
/// of `TaskCardView.body` so agent and session updates only re-render this.
private struct TaskCardActivityControls: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let task: ProjectTask

    var body: some View {
        // This task's thread is mid-turn.
        let isRunning = appState.isAgentRunning(for: task)
        Group {
            if isRunning {
                TaskRunningIndicator()
                    .transition(.opacity)
            }
            if appState.canOpenChat(for: task) {
                Button {
                    appState.openChat(for: task, in: windowState)
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Open Chat")
            }
        }
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isRunning)
    }
}

/// The running spinner on a story card: at least one of its tasks has a
/// thread mid-turn.
private struct StoryRunningIndicator: View {
    @Environment(AppState.self) private var appState

    let story: ProjectStory
    let board: TaskBoard

    var body: some View {
        let isRunning = appState.isAgentRunning(forStory: story, in: board)
        Group {
            if isRunning {
                TaskRunningIndicator(label: "An agent is working on this story's tasks")
                    .transition(.opacity)
            }
        }
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isRunning)
    }
}

/// "Verifying completion" bar shown while a task's completion check runs.
private struct TaskVerifyingIndicator: View {
    @Environment(AppState.self) private var appState

    let taskId: UUID

    var body: some View {
        if appState.verifyingTaskIds.contains(taskId) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Verifying completion")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Verifying completion")
            }
        }
    }
}

/// The "Starts after" row for a parent on another project's board. It reads
/// `AppState` here rather than in `TaskCardView`, so only cards with such a
/// link re-render when other boards change.
private struct TaskCardCrossProjectStartsAfterRow: View {
    @Environment(AppState.self) private var appState

    let parentID: UUID

    var body: some View {
        if let parent = appState.task(id: parentID) {
            TaskCardStartsAfterRow(
                parent: parent,
                board: appState.taskBoard(for: parent.projectId),
                projectName: appState.projects.first { $0.id == parent.projectId }?.name
            )
        }
    }
}

/// "Starts after" link to the task that must finish before this one starts,
/// with the blocking task's current column icon. `projectName` is set when
/// the parent is in another project.
private struct TaskCardStartsAfterRow: View {
    let parent: ProjectTask
    let board: TaskBoard
    var projectName: String?

    var body: some View {
        let isFinished = board.column(for: parent.status).countsAsDone
        let taskTitle = parent.title.isEmpty ? String(localized: "Untitled task") : parent.title
        let title = projectName.map { "\($0) · \(taskTitle)" } ?? taskTitle
        let help = isFinished
            ? String(localized: "Starts after \(title), which has finished")
            : String(localized: "Waits for \(title) to finish before starting")
        let tint = isFinished ? ClaudeTheme.textTertiary : ClaudeTheme.textSecondary
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
            Text("Starts after")
                .fixedSize()
            HStack(spacing: 4) {
                TaskStatusIcon(status: parent.status, board: board, size: 9)
                Text(verbatim: title)
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(isFinished)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.10)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .font(.system(size: ClaudeTheme.size(11)))
        .foregroundStyle(tint)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

/// Model details sit below the tags, with the assigned provider at the far edge.
private struct TaskCardModelRow: View {
    @Environment(AppState.self) private var appState

    let agent: TaskAgentConfig

    private var provider: AgentProvider { agent.provider ?? .claudeCode }

    private var providerLabel: String {
        guard provider == .acp,
              let clientId = appState.acpSelectionParts(for: agent.model)?.clientId,
              let client = appState.acpClients.first(where: { $0.id == clientId }) else {
            return provider.displayNameText
        }
        return client.displayName
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(appState.taskAgentLabel(agent))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            providerIcon
                .frame(width: 14, height: 14)
                .help(providerLabel)
                .accessibilityLabel(providerLabel)
        }
        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        .foregroundStyle(ClaudeTheme.textSecondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var providerIcon: some View {
        switch provider {
        case .claudeCode:
            Image("ClaudeProvider")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        case .codex:
            Image("CodexProvider")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        case .acp:
            let clientId = appState.acpSelectionParts(for: agent.model)?.clientId
            let iconURL = appState.acpClients.first(where: { $0.id == clientId })?.iconURL
            ACPIconView(url: iconURL, size: 14)
        }
    }
}
