import RxCodeCore
import SwiftUI

/// One task card on the board, laid out like a GitHub Projects item card:
/// a context line, the title, then field pills.
struct TaskCardView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let task: ProjectTask
    let board: TaskBoard
    /// The story under the pointer anywhere on the board, shared by every
    /// column so a story and its tasks light up together.
    @Binding var hoveredStoryId: UUID?
    let onOpen: () -> Void
    @State private var pendingDeletion: TaskBoardSheet?
    @State private var showsAttentionReason = false

    private var story: ProjectStory? { board.story(id: task.storyId) }

    /// This task's thread is mid-turn.
    private var isRunning: Bool { appState.isAgentRunning(for: task) }
    private var isVerifying: Bool { appState.verifyingTaskIds.contains(task.id) }

    var body: some View {
        let story = story
        let isRunning = isRunning
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                TaskStatusIcon(status: task.status, board: board, size: 11)
                if let story {
                    TaskStoryChip(
                        story: story,
                        progress: board.progress(for: story),
                        column: board.column(for: board.rolledUpStatus(for: story)),
                        hoveredStoryId: $hoveredStoryId
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

            Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            TaskSummaryPreview(task: task)

            if isVerifying {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verifying completion")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Verifying completion")
                }
            }

            if let reason = task.attentionReason {
                Text(reason)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusWarning)
                    .lineLimit(2)
            }

            if hasPills {
                FlowLayout(spacing: 4) {
                    TaskClassificationPills(task: task, board: board)
                    if task.agent.isAssigned {
                        TaskPill(text: appState.taskAgentLabel(task.agent), icon: "sparkles", tint: ClaudeTheme.statusRunning)
                    }
                    if task.agent.planMode {
                        TaskPill(text: String(localized: "Plan"), icon: "eye", tint: ClaudeTheme.statusWarning)
                    }
                    if !task.attachments.isEmpty {
                        TaskPill(text: "\(task.attachments.count)", icon: "paperclip")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isRunning)
        .modifier(TaskCardChrome(
            stripe: story?.tint,
            highlight: task.attentionReason != nil ? ClaudeTheme.statusWarning : story.flatMap { hoveredStoryId == $0.id ? $0.tint : nil },
            isDimmed: hoveredStoryId != nil && hoveredStoryId != task.storyId
        ))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            TaskContextMenuItems(task: task, onEdit: onOpen, onDelete: {
                pendingDeletion = .task(task)
            })
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .task(let task) = candidate { appState.deleteTask(task) }
        }
    }

    private var hasPills: Bool {
        TaskClassificationPills(task: task, board: board).hasContent || task.agent.isAssigned
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
    @Binding var hoveredStoryId: UUID?
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onOpen: () -> Void
    /// Opens the task form on a draft parented to this story.
    let onNewTask: (ProjectTask) -> Void
    @State private var pendingDeletion: TaskBoardSheet?

    /// At least one of this story's tasks has a thread mid-turn.
    private var isRunning: Bool {
        guard let board else { return false }
        return appState.isAgentRunning(forStory: story, in: board)
    }

    private var canCollapse: Bool {
        progress.total > 0 && progress.done == progress.total
    }

    var body: some View {
        let isRunning = isRunning
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(story.tint)
                Text("Story")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer(minLength: 0)
                if isRunning {
                    TaskRunningIndicator(label: "An agent is working on this story's tasks")
                        .transition(.opacity)
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
                StoryProgressBar(story: story, board: board)
            } else {
                StoryProgressBar(progress: progress)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isRunning)
        .modifier(TaskCardChrome(
            stripe: story.tint,
            highlight: hoveredStoryId == story.id ? story.tint : nil,
            isDimmed: hoveredStoryId != nil && hoveredStoryId != story.id
        ))
        .onHover { hovering in
            if hovering {
                hoveredStoryId = story.id
            } else if hoveredStoryId == story.id {
                hoveredStoryId = nil
            }
        }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            StoryContextMenuItems(story: story, onEdit: onOpen, onDelete: {
                pendingDeletion = .story(story)
            }, onNewTask: onNewTask)
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .story(let story) = candidate { appState.deleteStory(story) }
        }
    }
}

/// Shared card background, border and hover lift. `stripe` is the owning
/// story's color along the leading edge; `highlight` outlines the card while
/// its story is hovered, and `isDimmed` fades cards outside that story.
private struct TaskCardChrome: ViewModifier {
    var stripe: Color?
    var highlight: Color?
    var isDimmed = false

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
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
