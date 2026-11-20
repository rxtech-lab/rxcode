import RxCodeCore
import SwiftUI

/// Horizontally scrolling fixed-width columns, one per visible status, under
/// the keyword filter, beside a full-height story panel on the trailing edge. Stories stay out of the columns so they
/// never read as tasks.
struct TaskBoardLayoutView: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID
    let board: TaskBoard
    let view: TaskSavedView
    let tasks: [ProjectTask]
    let storyRollups: [UUID: StoryRollup]
    @Binding var keyword: String
    let stories: [ProjectStory]
    let onOpen: (TaskBoardSheet) -> Void
    let onAddTask: (TaskStatus, TaskCreationMode) -> Void
    let onAddStory: (TaskCreationMode) -> Void
    let onHideStatus: (TaskStatus) -> Void
    /// Saves the story panel's status filter on the view; empty shows all.
    let onChangeStoryPanelStatuses: ([TaskStatus]) -> Void
    let onEditView: () -> Void
    let onEditColumn: (TaskColumn) -> Void
    /// `(dragged, target)`: the dragged column takes the target's slot.
    let onReorderColumn: (TaskStatus, TaskStatus) -> Void
    let onAddColumn: () -> Void

    static let columnWidth: CGFloat = 320

    /// Shared by the story panel and every column: hovering a story or one of
    /// its tasks highlights the whole group. Handed to the
    /// cards through the environment; see `TaskBoardHoverState`.
    @State private var hoverState = TaskBoardHoverState()
    @State private var collapsedStoryIds = Set<UUID>()
    @State private var updatingModelTaskIds: Set<UUID> = []
    @State private var editingEffort: ProjectTask?
    @State private var agentUpdate: (id: UUID, message: String)?
    @State private var showsModelUpdateError = false

    private static func completedStoryIds(in rollups: [UUID: StoryRollup]) -> Set<UUID> {
        Set(rollups.compactMap { id, rollup in
            rollup.progress.total > 0 && rollup.progress.done == rollup.progress.total ? id : nil
        })
    }

    /// Where every card and column sits, hashed. Animating on this — rather
    /// than wrapping each drop in `withAnimation` — also covers moves nobody
    /// dragged: an agent finishing, a trigger advancing a card, a sync.
    private func layoutSignature(
        columns: [TaskColumn],
        taskStatus: (ProjectTask) -> TaskStatus,
        storyStatus: (ProjectStory) -> TaskStatus
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(columns.count)
        for column in columns { hasher.combine(column.id) }
        hasher.combine(tasks.count)
        for task in tasks {
            hasher.combine(task.id)
            hasher.combine(taskStatus(task))
            hasher.combine(task.sortIndex)
            hasher.combine(task.isQueued)
        }
        hasher.combine(stories.count)
        for story in stories {
            hasher.combine(story.id)
            hasher.combine(storyStatus(story))
        }
        return hasher.finalize()
    }

    var body: some View {
        // Board-wide derived state, computed once per update and handed down,
        // instead of every column and card re-deriving it from the whole board.
        let rollups = storyRollups
        let completedStoryIds = Self.completedStoryIds(in: rollups)
        let columns = view.visibleColumns(in: board.effectiveColumns)
        let taskStatus = { (task: ProjectTask) in board.resolvedStatus(of: task) }
        let storyStatus = { (story: ProjectStory) in
            rollups[story.id]?.status ?? board.rolledUpStatus(for: story)
        }
        let visibleColumnIds = Set(columns.map(\.id))
        // Stories whose rolled-up status is a hidden column stay hidden too,
        // ordered like the columns they roll up to.
        let columnStories = stories.filter { visibleColumnIds.contains(storyStatus($0)) }
        // The panel's own status filter narrows it further, without touching
        // the columns.
        let panelStories = columnStories
            .filter { view.storyPanelShows(storyStatus($0)) }
            .sorted {
                let lhs = board.columnIndex(of: storyStatus($0))
                let rhs = board.columnIndex(of: storyStatus($1))
                return lhs == rhs ? $0.updatedAt > $1.updatedAt : lhs < rhs
            }
        let visibleStoryIds = Set(panelStories.map(\.id))
        let collapsedVisibleStoryIds = collapsedStoryIds
            .intersection(visibleStoryIds)
            .intersection(completedStoryIds)
        let tasksByStatus = Dictionary(grouping: tasks.filter { task in
            !(task.storyId.map(collapsedVisibleStoryIds.contains) ?? false)
        }, by: taskStatus)
        let assignedProviders = Set(tasks.filter(\.agent.isAssigned).map {
            $0.agent.provider ?? appState.taskModelSelection(for: $0).provider
        })

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TaskFilterField(text: $keyword)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ScrollView(.horizontal) {
                    // Lazy so a wide board only builds the columns on screen — each
                    // column carries its own task card list.
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(columns) { column in
                            TaskColumnView(
                                projectId: projectId,
                                column: column,
                                tasks: (tasksByStatus[column.id] ?? []).sorted { $0.sortIndex < $1.sortIndex },
                                board: board,
                                view: view,
                                storyRollups: rollups,
                                onOpen: onOpen,
                                updatingModelTaskIds: updatingModelTaskIds,
                                onSelectModel: updateModel,
                                onEditEffort: { editingEffort = $0 },
                                onAddTask: { onAddTask(column.id, $0) },
                                onAddStory: onAddStory,
                                onHide: columns.count > 1 ? { onHideStatus(column.id) } : nil,
                                onEditView: onEditView,
                                onEditColumn: { onEditColumn(column) },
                                onReorder: { onReorderColumn($0, column.id) }
                            )
                            .frame(width: Self.columnWidth)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }

                        Button(action: onAddColumn) {
                            Label("Add Column", systemImage: "plus")
                                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                                        .strokeBorder(ClaudeTheme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add a column to this board")
                        .accessibilityIdentifier("task-add-column")
                    }
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .taskBoardAnimation(
                        value: layoutSignature(columns: columns, taskStatus: taskStatus, storyStatus: storyStatus)
                    )
                    .taskBoardAnimation(value: collapsedStoryIds)
                }
            }

            // Kept while the filter hides every story, so it can be undone.
            if !columnStories.isEmpty {
                TaskStoriesPanel(
                    stories: panelStories,
                    board: board,
                    storyRollups: rollups,
                    filterColumns: columns,
                    filterStatuses: view.storyPanelStatuses,
                    onChangeFilter: onChangeStoryPanelStatuses,
                    onOpen: onOpen,
                    onAddStory: onAddStory,
                    collapsedStoryIds: $collapsedStoryIds
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .taskBoardAnimation(value: columnStories.isEmpty)
        .environment(hoverState)
        .task(id: assignedProviders) {
            for provider in assignedProviders {
                await appState.loadReasoningLevels(for: provider)
            }
        }
        .sheet(item: $editingEffort) { task in
            TaskThinkingLevelSheet(task: task) {
                agentUpdate = (UUID(), String(localized: "Thinking level updated"))
            }
        }
        .overlay(alignment: .top) {
            if !updatingModelTaskIds.isEmpty || agentUpdate != nil {
                Group {
                    if updatingModelTaskIds.isEmpty, let agentUpdate {
                        Label(agentUpdate.message, systemImage: "checkmark.circle.fill")
                    } else {
                        ProgressView("Updating task model…")
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .allowsHitTesting(false)
            }
        }
        .task(id: agentUpdate?.id) {
            guard agentUpdate != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            agentUpdate = nil
        }
        .alert("Couldn’t Update Task Model", isPresented: $showsModelUpdateError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The task changed or is starting a run. Try again in a moment.")
        }
        .onChange(of: completedStoryIds) { _, completed in
            collapsedStoryIds.formIntersection(completed)
        }
    }

    private func updateModel(_ model: AgentModel?, for taskId: UUID) {
        guard updatingModelTaskIds.insert(taskId).inserted else { return }
        Task {
            let updated = await appState.updateTaskModel(model, for: taskId)
            updatingModelTaskIds.remove(taskId)
            if updated {
                agentUpdate = (UUID(), String(localized: "Task model updated"))
            } else {
                showsModelUpdateError = true
            }
        }
    }
}
