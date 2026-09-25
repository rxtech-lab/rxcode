import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// The sheet a story card opens on the overview: the story's summary, every
/// task that belongs to it, and an inline field for adding tasks without
/// leaving the sheet.
///
/// Takes ids rather than values and reads the story and its tasks live from
/// `AppState`, so quick-added tasks, status changes and edits made in the
/// nested form show up immediately.
struct StoryTasksSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let storyId: UUID
    let projectId: UUID

    @State private var newTaskTitle = ""
    @State private var editing: TaskBoardSheet?
    @FocusState private var isAddFieldFocused: Bool

    private var board: TaskBoard { appState.taskBoard(for: projectId) }
    private var story: ProjectStory? { board.story(id: storyId) }

    /// Open work first, in column order, then by board order within a column.
    private var tasks: [ProjectTask] {
        let board = board
        return board.tasks(inStory: storyId).sorted {
            let lhs = board.columnIndex(of: board.resolvedStatus(of: $0))
            let rhs = board.columnIndex(of: board.resolvedStatus(of: $1))
            return lhs == rhs ? $0.sortIndex < $1.sortIndex : lhs < rhs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let story {
                header(story)
                ClaudeThemeDivider()
                taskList
                ClaudeThemeDivider()
                addField
            } else {
                Spacer()
            }
        }
        .frame(width: 540, height: 600)
        .background(ClaudeTheme.background)
        .sheet(item: $editing) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: projectId)
                .environment(appState)
                .environment(windowState)
        }
        // Deleting the story from the nested edit form leaves nothing to show.
        .onChange(of: story == nil) { _, isGone in
            if isGone { dismiss() }
        }
        .onAppear {
            if tasks.isEmpty { isAddFieldFocused = true }
        }
    }

    // MARK: - Header

    private func header(_ story: ProjectStory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                    .foregroundStyle(story.tint)
                Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                    .font(.system(size: ClaudeTheme.size(17), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                TaskStatusIcon(status: board.rolledUpStatus(for: story), board: board, size: 13)

                Spacer(minLength: 8)

                Button {
                    editing = .story(story)
                } label: {
                    Label("Edit Story", systemImage: "pencil")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            let details = story.details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !details.isEmpty {
                MarkdownContentView(text: details)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let pills = TaskClassificationPills(story: story, board: board)
            if pills.hasContent {
                FlowLayout(spacing: 4) { pills }
            }

            StoryProgressBar(story: story, board: board)
        }
        .padding(20)
    }

    // MARK: - Tasks

    @ViewBuilder
    private var taskList: some View {
        let tasks = tasks
        if tasks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: ClaudeTheme.size(22)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text("No tasks in this story yet.")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text("Add one below.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    LazyVStack(spacing: 8) {
                        ForEach(tasks) { task in
                            StoryTaskRow(task: task) { editing = .task(task) }
                        }
                    }
                    .padding(16)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Quick add

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(ClaudeTheme.accent)
            TextField("Add a task…", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(.system(size: ClaudeTheme.size(13)))
                .focused($isAddFieldFocused)
                .onSubmit(addTask)
                .accessibilityIdentifier("story-sheet-add-task")
            Button("Add", action: addTask)
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(trimmedNewTitle.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(16)
    }

    private var trimmedNewTitle: String {
        newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a pending task in this story and keeps focus in the field so
    /// several tasks can be typed in a row.
    private func addTask() {
        let title = trimmedNewTitle
        guard !title.isEmpty else { return }
        appState.quickAddTask(title: title, projectId: projectId, storyId: storyId)
        newTaskTitle = ""
        isAddFieldFocused = true
    }
}

/// One task inside the story sheet. The status glyph is a menu for quick
/// moves; the rest of the row opens the full edit form.
private struct StoryTaskRow: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let task: ProjectTask
    let onOpen: () -> Void

    private var isDone: Bool { board.column(for: task.status).countsAsDone }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Menu {
                ForEach(board.effectiveColumns) { column in
                    Button(column.name) {
                        appState.moveTask(task, to: column.id)
                    }
                    .disabled(column.id == board.resolvedStatus(of: task))
                }
            } label: {
                TaskStatusIcon(status: task.status, board: board, size: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(board.isStatusLocked(task))
            .help(board.isStatusLocked(task) ? "The agent is working on this task" : "Change status")

            VStack(alignment: .leading, spacing: 5) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                            .foregroundStyle(isDone ? ClaudeTheme.textSecondary : ClaudeTheme.textPrimary)
                            .strikethrough(isDone, color: ClaudeTheme.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if hasPills {
                            FlowLayout(spacing: 4) {
                                TaskClassificationPills(task: task, board: board)
                                if task.agent.isAssigned {
                                    TaskPill(text: appState.taskAgentLabel(task.agent), icon: "sparkles", tint: ClaudeTheme.statusRunning)
                                }
                                if isClassifying {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.mini)
                                        Text("Filling in properties…")
                                            .font(.system(size: ClaudeTheme.size(10)))
                                            .foregroundStyle(ClaudeTheme.textTertiary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Outside the row's button: it has its own tap target.
                TaskSummaryPreview(task: task)
            }

            if appState.canOpenChat(for: task) {
                Button {
                    dismiss()
                    appState.openChat(for: task, in: windowState)
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Open Chat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        .contextMenu {
            TaskContextMenuItems(task: task, onEdit: onOpen, onOpenChat: { dismiss() })
        }
    }

    private var board: TaskBoard { appState.taskBoard(for: task.projectId) }
    private var isClassifying: Bool { appState.classifyingTaskIds.contains(task.id) }

    private var hasPills: Bool {
        TaskClassificationPills(task: task, board: board).hasContent || task.agent.isAssigned || isClassifying
    }
}
