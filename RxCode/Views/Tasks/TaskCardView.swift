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

    private var story: ProjectStory? { board.story(id: task.storyId) }

    var body: some View {
        let story = story
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
        .modifier(TaskCardChrome(
            stripe: story?.tint,
            highlight: story.flatMap { hoveredStoryId == $0.id ? $0.tint : nil },
            isDimmed: hoveredStoryId != nil && hoveredStoryId != task.storyId
        ))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            TaskContextMenuItems(task: task, onEdit: onOpen)
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
    let story: ProjectStory
    let progress: StoryProgress
    var board: TaskBoard?
    @Binding var hoveredStoryId: UUID?
    let onOpen: () -> Void
    /// Opens the task form on a draft parented to this story.
    let onNewTask: (ProjectTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(story.tint)
                Text("Story")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer(minLength: 0)
                if progress.total > 0 {
                    Text("\(progress.total) tasks")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .help("Hover to highlight this story's tasks")
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
            StoryContextMenuItems(story: story, onEdit: onOpen, onNewTask: onNewTask)
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
