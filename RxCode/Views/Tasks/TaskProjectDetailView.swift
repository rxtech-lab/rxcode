import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// One project's task page, laid out like a GitHub Project: a row of view tabs
/// (each a saved board or table with its own filters), a keyword filter, and
/// the selected view's content.
struct TaskProjectDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let project: Project
    @Binding var sheet: TaskBoardSheet?

    @State private var selectedViewId: UUID?
    @State private var keyword = ""
    @State private var viewEditor: TaskViewEditorPayload?
    /// The view awaiting delete confirmation.
    @State private var pendingViewDeletion: TaskSavedView?
    @State private var showingLabelManager = false
    @State private var columnEditor: TaskColumnEditorPayload?
    @State private var showingColumnManager = false
    /// The latest run of the current view's Swift filter.
    @State private var scriptFilterResult: ScriptFilterResult?
    @State private var isEvaluatingScriptFilter = false

    private var board: TaskBoard { appState.taskBoard(for: project.id) }
    private var views: [TaskSavedView] { appState.taskViews(for: project.id) }

    /// The picked tab, else the project's default view.
    private var currentView: TaskSavedView {
        views.first { $0.id == selectedViewId } ?? board.defaultView
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            viewTabs
            // The board places the filter over its columns, beside the story
            // panel, so the panel runs the full height.
            if currentView.layout != .board {
                TaskFilterField(text: $keyword)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            content
        }
        .task(id: scriptFilterKey) { await runScriptFilter() }
        .onAppear {
            AnalyticsService.shared.log(.taskProjectBoardOpened, parameters: [
                "project_type": project.cloudId == nil ? "local" : "cloud"
            ])
        }
        .sheet(item: $viewEditor) { payload in
            TaskViewFormSheet(payload: payload) { saved in
                selectedViewId = saved.id
            }
            .environment(appState)
        }
        .sheet(item: $columnEditor) { payload in
            TaskColumnFormSheet(payload: payload)
                .environment(appState)
        }
        .sheet(isPresented: $showingColumnManager) {
            TaskColumnsSheet(projectId: project.id)
                .environment(appState)
        }
        .sheet(isPresented: $showingLabelManager) {
            TaskFieldsSheet(projectId: project.id)
                .environment(appState)
        }
        .confirmationDialog(
            "Delete view “\(pendingViewDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingViewDeletion != nil },
                set: { if !$0 { pendingViewDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingViewDeletion
        ) { pending in
            Button("Delete", role: .destructive) {
                delete(pending)
            }
        } message: { _ in
            Text("Its layout and filters will be removed. Tasks are not affected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                windowState.taskDetailProjectId = nil
            } label: {
                Label("All Projects", systemImage: "chevron.left")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier("task-detail-back")

            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: ClaudeTheme.size(16)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text(project.name)
                    .font(.system(size: ClaudeTheme.size(20), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                ProjectCloudBadge(project: project, size: 13)
                if let phase = appState.cloudSyncPhaseByProjectId[project.id] {
                    HStack(spacing: 6) {
                        ProjectCloudSyncRing(phase: phase)
                        Text(phase.progressText)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }

                Spacer()

                ProjectCloudButton(project: project)

                Menu {
                    TaskCreationMenuItems(
                        onNewTask: { openNewTask(mode: $0) },
                        onNewStory: { openNewStory(mode: $0) }
                    )

                    Divider()

                    Button {
                        appState.startNewChat(inProject: project.id, window: windowState)
                    } label: {
                        Label("New Chat", systemImage: "bubble.left.and.bubble.right")
                    }

                    Divider()

                    Button {
                        showingColumnManager = true
                    } label: {
                        Label("Columns", systemImage: "rectangle.split.3x1")
                    }

                    Button {
                        showingLabelManager = true
                    } label: {
                        Label("Fields", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    ProjectCloudMenuItems(project: project)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help("New task, story or chat, or manage columns and fields")
                .accessibilityIdentifier("task-project-add")
                .background {
                    // Menu items don't register key equivalents, so keep ⇧⌘N on a hidden button.
                    Button("") {
                        openNewTask(mode: nil)
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - View tabs

    private var viewTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(views) { view in
                    TaskViewTab(
                        view: view,
                        isSelected: view.id == currentView.id,
                        isDefault: view.id == board.defaultView.id,
                        showsDefaultBadge: views.count > 1,
                        isEvaluatingScript: view.id == currentView.id && isEvaluatingScriptFilter,
                        scriptError: view.id == currentView.id ? scriptFilterError : nil,
                        canDelete: views.count > 1,
                        onSelect: { selectedViewId = view.id },
                        onEdit: { viewEditor = TaskViewEditorPayload(projectId: project.id, view: view, isNew: false) },
                        onDuplicate: { duplicate(view) },
                        onSetDefault: { appState.setDefaultSavedView(view.id, projectId: project.id) },
                        onDelete: { pendingViewDeletion = view },
                        onReorder: { appState.reorderSavedView($0, onto: view.id, projectId: project.id) }
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                Button {
                    viewEditor = TaskViewEditorPayload(
                        projectId: project.id,
                        view: TaskSavedView(name: String(localized: "New view")),
                        isNew: true
                    )
                } label: {
                    Label("New view", systemImage: "plus")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("task-new-view")
            }
            .padding(.horizontal, 16)
            // Tabs slide into their new slot after a drag, and new or
            // deleted views grow in and out.
            .taskBoardAnimation(value: views.map(\.id))
        }
        .overlay(alignment: .bottom) {
            ClaudeThemeDivider()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let view = currentView
        let selection = scriptFilterSelection
        let tasks = board.tasks
            .filter {
                view.matches($0) && $0.matches(keyword: keyword)
                    && (selection?.taskIds.contains($0.id) ?? true)
            }
        switch view.layout {
        case .board:
            TaskBoardLayoutView(
                board: board,
                view: view,
                tasks: tasks,
                keyword: $keyword,
                stories: board.stories.filter {
                    view.matches($0, rolledUpStatus: board.rolledUpStatus(for: $0)) && $0.matches(keyword: keyword)
                        && (selection?.storyIds.contains($0.id) ?? true)
                },
                onOpen: { sheet = $0 },
                onAddTask: { status, mode in
                    sheet = .task(newTask(status: status), mode: mode)
                },
                onAddStory: { openNewStory(mode: $0) },
                onHideStatus: { hide($0, in: view) },
                onChangeStoryPanelStatuses: { setStoryPanelStatuses($0, in: view) },
                onEditView: { viewEditor = TaskViewEditorPayload(projectId: project.id, view: view, isNew: false) },
                onEditColumn: { columnEditor = TaskColumnEditorPayload(projectId: project.id, column: $0, isNew: false) },
                onReorderColumn: reorderColumn,
                onAddColumn: {
                    columnEditor = TaskColumnEditorPayload(
                        projectId: project.id,
                        column: TaskColumn(name: "", colorHex: TaskLabel.palette[board.effectiveColumns.count % TaskLabel.palette.count]),
                        isNew: true
                    )
                }
            )
        case .table:
            TaskTableLayoutView(
                board: board,
                tasks: tasks.sorted {
                    let lhs = board.columnIndex(of: board.resolvedStatus(of: $0))
                    let rhs = board.columnIndex(of: board.resolvedStatus(of: $1))
                    return lhs == rhs ? $0.sortIndex < $1.sortIndex : lhs < rhs
                },
                onOpen: { sheet = $0 }
            )
            .padding(.top, 12)
        }
    }

    // MARK: - Swift filter

    private struct ScriptFilterResult {
        let viewId: UUID
        let script: String
        let outcome: TaskFilterScriptEvaluator.Outcome
    }

    /// Changes whenever the current view's script or anything it can see on
    /// the board changes; `nil` when the view has no script.
    private var scriptFilterKey: Int? {
        let view = currentView
        guard view.hasFilterScript, let script = view.filterScript else { return nil }
        var hasher = Hasher()
        hasher.combine(view.id)
        hasher.combine(script)
        hasher.combine(board.tasks)
        hasher.combine(board.stories)
        hasher.combine(board.effectiveColumns)
        hasher.combine(board.effectiveTypes)
        return hasher.finalize()
    }

    /// The last result for the current view's script. A result for an older
    /// board keeps applying until the rerun lands, so edits don't flash the
    /// unfiltered board; until the first run finishes nothing is filtered.
    private var currentScriptFilterResult: ScriptFilterResult? {
        let view = currentView
        guard view.hasFilterScript,
              let result = scriptFilterResult,
              result.viewId == view.id,
              result.script == view.filterScript
        else { return nil }
        return result
    }

    private var scriptFilterSelection: TaskFilterScript.Selection? {
        guard case .selection(let selection)? = currentScriptFilterResult?.outcome else { return nil }
        return selection
    }

    private var scriptFilterError: String? {
        guard case .failure(let message)? = currentScriptFilterResult?.outcome else { return nil }
        return message
    }

    private func runScriptFilter() async {
        let view = currentView
        guard view.hasFilterScript, let script = view.filterScript else {
            isEvaluatingScriptFilter = false
            return
        }
        // Coalesce bursts of board edits (an agent moving cards) into one run.
        if currentScriptFilterResult != nil {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        isEvaluatingScriptFilter = true
        let outcome = await appState.evaluateTaskFilterScript(script, projectId: project.id)
        guard !Task.isCancelled else { return }
        scriptFilterResult = ScriptFilterResult(viewId: view.id, script: script, outcome: outcome)
        isEvaluatingScriptFilter = false
    }

    // MARK: - Actions

    /// A draft pre-filled from the current view's filters, so a task created
    /// inside a filtered view shows up in it. A multi-value filter only
    /// pre-fills when it names a single value.
    private func openNewTask(mode: TaskCreationMode?) {
        sheet = .task(newTask(status: board.firstColumn.id), mode: mode)
    }

    private func openNewStory(mode: TaskCreationMode?) {
        sheet = .story(ProjectStory(projectId: project.id, title: ""), mode: mode)
    }

    private func newTask(status: TaskStatus) -> ProjectTask {
        let view = currentView
        return ProjectTask(
            projectId: project.id,
            storyId: view.storyIds.count == 1 ? view.storyIds.first : nil,
            title: "",
            status: status,
            version: view.versions.count == 1 ? view.versions.first : nil,
            tags: view.tags,
            milestone: view.milestones.count == 1 ? view.milestones.first : nil
        )
    }

    private func duplicate(_ view: TaskSavedView) {
        let copy = TaskSavedView(
            name: String(localized: "\(view.name) copy"),
            layout: view.layout,
            tags: view.tags,
            versions: view.versions,
            milestones: view.milestones,
            storyIds: view.storyIds,
            statuses: view.statuses,
            filterScript: view.filterScript
        )
        appState.upsertSavedView(copy, projectId: project.id)
        selectedViewId = copy.id
    }

    private func delete(_ view: TaskSavedView) {
        appState.deleteSavedView(view, projectId: project.id)
        if selectedViewId == view.id { selectedViewId = nil }
    }

    /// Board drag-and-drop: `dragged` takes `target`'s slot, the same reorder
    /// the columns manager applies with its list drag.
    private func reorderColumn(_ dragged: TaskStatus, onto target: TaskStatus) {
        guard let order = board.columnOrder(moving: dragged, to: target) else { return }
        appState.reorderColumns(order, projectId: project.id)
    }

    private func setStoryPanelStatuses(_ statuses: [TaskStatus], in view: TaskSavedView) {
        guard statuses != view.storyPanelStatuses else { return }
        var updated = view
        updated.storyPanelStatuses = statuses
        appState.upsertSavedView(updated, projectId: project.id)
    }

    private func hide(_ status: TaskStatus, in view: TaskSavedView) {
        var updated = view
        let remaining = view.visibleColumns(in: board.effectiveColumns).map(\.id).filter { $0 != status }
        // Hiding the last column would leave an empty board; keep it.
        guard !remaining.isEmpty else { return }
        updated.statuses = remaining
        appState.upsertSavedView(updated, projectId: project.id)
    }
}

// MARK: - Tab

/// One view tab. The selected tab is boxed and carries a dropdown for view
/// actions, like GitHub's active project view.
private struct TaskViewTab: View {
    let view: TaskSavedView
    let isSelected: Bool
    /// The view the project opens on and its dashboard card previews.
    let isDefault: Bool
    /// Marks the default tab — pointless while it is the only one.
    let showsDefaultBadge: Bool
    /// The view's Swift filter is running.
    let isEvaluatingScript: Bool
    /// Why the view's Swift filter failed, if it did.
    let scriptError: String?
    let canDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void
    /// Called with the id of a tab dropped onto this one.
    let onReorder: (UUID) -> Void

    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            // Only the icon and name carry the drag: the chevron menu beside
            // them has to stay clickable.
            HStack(spacing: 6) {
                Image(systemName: view.layout.systemImage)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                Text(view.name)
                    .font(.system(size: ClaudeTheme.size(12), weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if isDefault && showsDefaultBadge {
                    Image(systemName: "star.fill")
                        .font(.system(size: ClaudeTheme.size(8)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .help("Default view")
                        .accessibilityLabel("Default view")
                }
                if view.hasFilterScript {
                    scriptBadge
                }
            }
            .contentShape(Rectangle())
            .draggable(TaskViewTransfer(viewId: view.id)) {
                TaskViewDragPreview(view: view)
            }

            if isSelected {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: ClaudeTheme.size(8), weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("View options")
            }
        }
        .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tabShape.fill(isSelected ? ClaudeTheme.surfacePrimary : (isHovering ? ClaudeTheme.sidebarItemHover : .clear)))
        .overlay(
            tabShape.stroke(isSelected ? ClaudeTheme.border : .clear, lineWidth: 1)
        )
        // The dragged tab lands in this tab's slot.
        .taskDropHighlight(isDropTargeted, in: tabShape, scale: 1.04)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isHovering)
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isSelected)
        .contextMenu { menuItems }
        .dropDestination(for: TaskViewTransfer.self) { items, _ in
            guard let dragged = items.first?.viewId, dragged != view.id else { return false }
            onReorder(dragged)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityIdentifier("task-view-tab-\(view.name)")
    }

    /// Marks a view filtered by Swift code: a spinner while it runs, a
    /// warning when it failed.
    @ViewBuilder
    private var scriptBadge: some View {
        if isEvaluatingScript {
            ProgressView().controlSize(.mini)
        } else if let scriptError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.statusError)
                .help(scriptError)
        } else {
            Image(systemName: "curlybraces")
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .help("Filtered by Swift code")
        }
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ClaudeTheme.cornerRadiusSmall,
            topTrailingRadius: ClaudeTheme.cornerRadiusSmall
        )
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit View…", action: onEdit)
        Button("Duplicate View", action: onDuplicate)
        Button("Set as Default View", action: onSetDefault)
            .disabled(isDefault)
        Divider()
        Button("Delete View", role: .destructive, action: onDelete)
            .disabled(!canDelete)
    }
}

// MARK: - Tab drag

/// The drag payload of a view tab. A dedicated type so a tab can't be dropped
/// onto a board column or card target, or the other way round.
struct TaskViewTransfer: Codable, Sendable, Transferable {
    let viewId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rxCodeTaskView)
    }
}

extension UTType {
    /// Declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    static let rxCodeTaskView = UTType(exportedAs: "com.rxlab.RxCode.task-view")
}

/// The chip that follows the pointer while a view tab is dragged.
private struct TaskViewDragPreview: View {
    let view: TaskSavedView

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        HStack(spacing: 6) {
            Image(systemName: view.layout.systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            Text(view.name)
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ClaudeTheme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ClaudeTheme.surfacePrimary, in: shape)
        .overlay(shape.strokeBorder(ClaudeTheme.border, lineWidth: 1))
    }
}

// MARK: - Board layout

/// Horizontally scrolling fixed-width columns, one per visible status, under
/// the keyword filter, beside a full-height story panel on the trailing edge. Stories stay out of the columns so they
/// never read as tasks.
struct TaskBoardLayoutView: View {
    let board: TaskBoard
    let view: TaskSavedView
    let tasks: [ProjectTask]
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
        let rollups = board.storyRollups()
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
                                column: column,
                                tasks: (tasksByStatus[column.id] ?? []).sorted { $0.sortIndex < $1.sortIndex },
                                board: board,
                                storyRollups: rollups,
                                onOpen: onOpen,
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
        .onChange(of: completedStoryIds) { _, completed in
            collapsedStoryIds.formIntersection(completed)
        }
    }
}

// MARK: - Table layout

/// Spreadsheet-style list of tasks — GitHub's table layout.
struct TaskTableLayoutView: View {
    @Environment(AppState.self) private var appState

    let board: TaskBoard
    let tasks: [ProjectTask]
    let onOpen: (TaskBoardSheet) -> Void

    @State private var selection = Set<UUID>()
    @State private var pendingDeletion: TaskBoardSheet?

    var body: some View {
        Table(tasks, selection: $selection) {
            TableColumn("Title") { task in
                HStack(spacing: 6) {
                    TaskStatusIcon(status: task.status, board: board)
                    Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                        .lineLimit(1)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Status") { task in
                Text(board.column(for: task.status).name)
                    .foregroundStyle(board.column(for: task.status).tint)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Type") { task in
                if let type = board.itemType(id: task.typeId) {
                    TaskPill(text: type.name, icon: "circle.fill", tint: type.tint)
                }
            }
            .width(min: 60, ideal: 90)

            TableColumn("Priority") { task in
                if let priority = task.priority {
                    Label {
                        Text(priority.displayName)
                    } icon: {
                        Image(systemName: priority.systemImage)
                    }
                    .foregroundStyle(priority.tint)
                }
            }
            .width(min: 60, ideal: 90)

            TableColumn("Story") { task in
                Text(board.story(id: task.storyId)?.title ?? "")
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 160)

            TableColumn("Version") { task in
                if let version = task.version, !version.isEmpty {
                    TaskPill(text: version, icon: "tag", tint: ClaudeTheme.accent)
                }
            }
            .width(min: 60, ideal: 90)

            TableColumn("Milestone") { task in
                if let milestone = task.milestone, !milestone.isEmpty {
                    TaskPill(text: milestone, icon: "flag", tint: ClaudeTheme.statusSuccess)
                }
            }
            .width(min: 60, ideal: 100)

            TableColumn("Tags") { task in
                HStack(spacing: 4) {
                    ForEach(task.tags, id: \.self) { TaskPill(text: $0, tint: board.tint(forTag: $0)) }
                }
            }
            .width(min: 80, ideal: 180)

            TableColumn("Agent") { task in
                Text(appState.taskAgentLabel(task.agent))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let task = tasks.first(where: { $0.id == id }) {
                TaskContextMenuItems(task: task, onEdit: { onOpen(.task(task)) }, onDelete: {
                    pendingDeletion = .task(task)
                })
            }
        } primaryAction: { ids in
            guard let id = ids.first, let task = tasks.first(where: { $0.id == id }) else { return }
            onOpen(.task(task))
        }
        .overlay {
            if tasks.isEmpty {
                Text("No tasks match this view.")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .task(let task, _) = candidate { appState.deleteTask(task) }
        }
    }
}
