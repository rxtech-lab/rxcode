import RxCodeCore
import RxCodeSync
import SwiftUI

/// A project's task board: tasks grouped by column, and stories with their
/// rolled-up progress. On iPhone the columns are list sections; on iPad they
/// sit side by side as a Kanban board, like the Mac. The same board UI supports
/// desktop-backed and direct cloud projects. Agent runs require a connected Mac.
struct MobileTaskBoardView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case tasks
        case stories

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .tasks: "Tasks"
            case .stories: "Stories"
            }
        }
    }

    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    let projectID: UUID
    /// Opens a chat thread in the host (after this board is dismissed).
    var onOpenChat: ((String) -> Void)?
    /// True when presented in its own sheet: shows Done, owns its navigation
    /// destinations, and dismisses itself before opening a chat. False when
    /// pushed inside the Tasks dashboard's stack.
    var isModal = true

    @State private var viewFeedback: String?
    @State private var isSavingView = false
    @State private var mode: Mode = .tasks
    @State private var selectedViewID: UUID?
    @State private var editingView: MobileViewEditorPayload?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editingTask: ProjectTask?
    @State private var editingStory: ProjectStory?
    @State private var showingQuickAdd = false
    @State private var collapsedColumns: Set<TaskStatus> = []
    @State private var runRequest: MobileTaskRunRequest?

    private var project: Project? {
        state.taskProjects.first { $0.id == projectID }
    }

    private var board: TaskBoard {
        state.taskBoard(for: projectID)
    }

    private var views: [TaskSavedView] { board.effectiveViews }

    /// The picked view, else the project's default view.
    private var currentView: TaskSavedView {
        views.first { $0.id == selectedViewID } ?? board.defaultView
    }

    private var visibleTasks: [ProjectTask] {
        board.tasks.filter { currentView.matches($0) && $0.matches(keyword: searchText) }
    }

    private var visibleStories: [ProjectStory] {
        board.stories.filter {
            currentView.matches($0, rolledUpStatus: board.rolledUpStatus(for: $0))
                && $0.matches(keyword: searchText)
        }
    }

    private var hasLoaded: Bool {
        state.taskSnapshots[projectID] != nil
    }

    /// iPad: columns side by side, with the view picker in the toolbar.
    private var isRegularWidth: Bool { UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular }

    var body: some View {
        boardContent
        .navigationTitle(project?.name ?? String(localized: "Tasks"))
        .onAppear {
            guard let project else { return }
            AnalyticsService.shared.log(.taskProjectBoardOpened, parameters: [
                "project_type": project.cloudId == nil ? "local" : "cloud"
            ])
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("Filter tasks"))
        .overlay {
            if !isRegularWidth || !hasLoaded {
                boardStatusContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .topTrailing) {
            if isSavingView {
                ProgressView("Saving view…").padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            } else if let viewFeedback {
                Label(viewFeedback, systemImage: "checkmark.circle.fill")
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
        }
        .task(id: viewFeedback) {
            guard viewFeedback != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            viewFeedback = nil
        }
        .modifier(MobileTaskDestinations(isEnabled: isModal, onOpenChat: openChat))
        .task(id: state.taskSyncReloadKey) {
            state.restoreCloudTaskCacheIfNeeded()
            guard state.isTaskSyncReady else { return }
            await load()
        }
        .sheet(item: $editingTask) { task in
            NavigationStack {
                MobileTaskFormView(task: task, isNew: !board.tasks.contains { $0.id == task.id })
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.large])
        }
        .sheet(item: $editingStory) { story in
            NavigationStack {
                MobileStoryFormView(story: story, isNew: board.story(id: story.id) == nil)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.large])
        }
        .sheet(isPresented: $showingQuickAdd) {
            NavigationStack {
                MobileQuickAddTaskView(projectID: projectID, storyID: nil)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.medium, .large])
        }
        .sheet(item: $editingView) { payload in
            NavigationStack {
                MobileTaskViewForm(projectID: projectID, view: payload.view) { saved in
                    selectedViewID = saved.id
                }
                .environmentObject(state)
            }
            .mobileSheetPresentation([.large])
        }
        .mobileTaskRunDevicePicker($runRequest)
        .mobileTaskErrorAlert($errorMessage)
    }

    @ViewBuilder
    private var boardContent: some View {
        if isRegularWidth && hasLoaded && (mode == .tasks ? visibleTasks.isEmpty : visibleStories.isEmpty) {
            boardStatusContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-board-empty-state")
        } else if isRegularWidth && mode == .tasks && currentView.layout == .board {
            kanbanBoard
        } else {
            List {
                if !isRegularWidth {
                    Section {
                        modePicker
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }

                switch mode {
                case .tasks:
                    if currentView.layout == .table {
                        tableSection
                    } else {
                        taskSections
                    }
                case .stories:
                    storySection
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Kanban (iPad)

    /// Scrolls horizontally only; each column fits the visible height and
    /// scrolls its own cards, so the last card is never cut off.
    private var kanbanBoard: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(currentView.visibleColumns(in: board.effectiveColumns)) { column in
                        kanbanColumn(column, height: max(proxy.size.height - 32, 0))
                    }
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("tasks-ipad-kanban")
    }

    private func kanbanColumn(_ column: TaskColumn, height: CGFloat) -> some View {
        let tasks = board.tasks(in: column.id).filter { currentView.matches($0) && $0.matches(keyword: searchText) }
        return TaskKanbanColumnContent(
            headerSpacing: 0,
            cardInsets: EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8)
        ) {
            HStack(spacing: 6) {
                Image(systemName: column.systemImage)
                    .foregroundStyle(column.tint)
                Text(column.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(tasks.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityIdentifier("task-column-\(column.id.rawValue)")

        } cards: {
            ForEach(tasks) { task in
                MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                    MobileTaskRow(task: task, board: board)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .modifier(MobileTaskActions(
                    task: task,
                    board: board,
                    onEdit: { editingTask = task },
                    onOpenChat: openChat,
                    onError: { errorMessage = $0 }
                ))
                .modifier(MobileTaskDraggable(task: task, isEnabled: !board.isStatusLocked(task)))
                .dropDestination(for: String.self) { items, _ in
                    drop(items, before: task, in: column.id)
                }
            }
        }
        .frame(width: 300, height: height, alignment: .top)
        .background(column.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(column.tint.opacity(0.18)))
        // Dropping anywhere else in the column appends to its end.
        .dropDestination(for: String.self) { items, _ in
            drop(items, before: nil, in: column.id)
        }
    }

    // MARK: - Tasks

    private var tableSection: some View {
        Section {
            ForEach(visibleTasks.sorted { lhs, rhs in
                let left = board.columnIndex(of: board.resolvedStatus(of: lhs))
                let right = board.columnIndex(of: board.resolvedStatus(of: rhs))
                return left == right ? lhs.sortIndex < rhs.sortIndex : left < right
            }) { task in
                MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                    MobileTaskRow(task: task, board: board)
                }
                .modifier(MobileTaskActions(
                    task: task,
                    board: board,
                    onEdit: { editingTask = task },
                    onOpenChat: openChat,
                    onError: { errorMessage = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private var taskSections: some View {
        ForEach(currentView.visibleColumns(in: board.effectiveColumns)) { column in
            let tasks = board.tasks(in: column.id).filter { currentView.matches($0) && $0.matches(keyword: searchText) }
            if !tasks.isEmpty || searchText.isEmpty {
                Section {
                    if !collapsedColumns.contains(column.id) {
                        ForEach(tasks) { task in
                            MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                                MobileTaskRow(task: task, board: board)
                            }
                            .modifier(MobileTaskActions(
                                task: task,
                                board: board,
                                onEdit: { editingTask = task },
                                onOpenChat: openChat,
                                onError: { errorMessage = $0 }
                            ))
                            .modifier(MobileTaskDraggable(task: task, isEnabled: !board.isStatusLocked(task)))
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, before: task, in: column.id)
                            }
                        }
                    }
                } header: {
                    columnHeader(column, count: tasks.count)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, before: nil, in: column.id)
                        }
                }
            }
        }
    }

    private func columnHeader(_ column: TaskColumn, count: Int) -> some View {
        Button {
            withAnimation {
                if collapsedColumns.contains(column.id) {
                    collapsedColumns.remove(column.id)
                } else {
                    collapsedColumns.insert(column.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: column.systemImage)
                    .foregroundStyle(column.tint)
                Text(column.name)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(collapsedColumns.contains(column.id) ? 0 : 90))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task-column-\(column.id.rawValue)")
    }

    // MARK: - Stories

    @ViewBuilder
    private var storySection: some View {
        let rollups = board.storyRollups()
        let stories = visibleStories.sorted { $0.updatedAt > $1.updatedAt }
        Section {
            ForEach(stories) { story in
                MobileTaskDetailButton(route: MobileTaskRoute.story(projectID: projectID, storyID: story.id), onOpenChat: openChat) {
                    MobileStoryRow(story: story, board: board, rollup: rollups[story.id])
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        perform { try await state.deleteStory(story) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingStory = story
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var boardStatusContent: some View {
        if !hasLoaded && isLoading {
            ProgressView("Loading tasks…")
        } else if hasLoaded {
            switch mode {
            case .tasks where visibleTasks.isEmpty:
                if board.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "checklist",
                        description: Text("Add a task to start planning your project.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Matching Tasks",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try another view or search.")
                    )
                }
            case .stories where visibleStories.isEmpty:
                if board.stories.isEmpty {
                    ContentUnavailableView(
                        "No Stories",
                        systemImage: "rectangle.stack",
                        description: Text("Stories group related tasks and roll up their progress.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Matching Stories",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try another view or search.")
                    )
                }
            default:
                EmptyView()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isModal {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        if isRegularWidth {
            ToolbarItem(placement: .principal) {
                modePicker
                    .frame(width: 220)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(views) { view in
                    Button {
                        selectedViewID = view.id
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label(view.name, systemImage: view.id == currentView.id ? "checkmark" : view.layout.systemImage)
                    }
                }
                Divider()
                Button {
                    editingView = MobileViewEditorPayload(view: TaskSavedView(name: String(localized: "New view")))
                } label: {
                    Label("New View", systemImage: "plus")
                }
                Button {
                    editingView = MobileViewEditorPayload(view: currentView)
                } label: {
                    Label("Edit View", systemImage: "pencil")
                }
                Button {
                    setDefault(currentView)
                } label: {
                    Label("Set as Default View", systemImage: "star")
                }
                .disabled(currentView.id == board.defaultView.id)
            } label: {
                Label(currentView.name, systemImage: currentView.layout.systemImage)
            }
            .disabled(!hasLoaded || isSavingView)
            .accessibilityIdentifier("task-board-views")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    editingTask = newTaskDraft()
                } label: {
                    Label("New Task", systemImage: "square.and.pencil")
                }
                if !state.usesCloudTasks {
                Button {
                    showingQuickAdd = true
                } label: {
                    Label("Quick Add Task", systemImage: "sparkles")
                }
                }
                Button {
                    editingStory = ProjectStory(projectId: projectID, title: "")
                } label: {
                    Label("New Story", systemImage: "rectangle.stack.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!hasLoaded)
            .accessibilityIdentifier("task-board-add")
        }
    }

    // MARK: - Actions

    private func newTaskDraft() -> ProjectTask {
        let view = currentView
        let storyId = view.storyIds.count == 1 ? view.storyIds.first : nil
        var draft = state.newTaskDraft(projectID: projectID, story: board.story(id: storyId))
        if view.versions.count == 1 { draft.version = view.versions.first }
        if view.milestones.count == 1 { draft.milestone = view.milestones.first }
        draft.tags = view.tags
        draft.status = view.visibleColumns(in: board.effectiveColumns).first?.id ?? board.firstColumn.id
        return draft
    }

    private func setDefault(_ view: TaskSavedView) {
        var updated = view
        updated.isDefault = true
        selectedViewID = view.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isSavingView = true
        Task {
            defer { isSavingView = false }
            do {
                try await state.saveView(updated, projectID: projectID)
                viewFeedback = String(localized: "Default view updated")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await state.loadTaskBoard(projectID: projectID)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Handles a task card dropped on a row (placed before it) or a column
    /// header (appended to the column).
    private func drop(_ items: [String], before target: ProjectTask?, in status: TaskStatus) -> Bool {
        guard let taskID = items.first.flatMap(UUID.init(uuidString:)),
              let task = board.tasks.first(where: { $0.id == taskID })
        else { return false }
        if task.id != target?.id, state.moveStartsRun(task, to: status) {
            // Dropping into a run column asks which Mac runs it first.
            runRequest = MobileTaskRunRequest(
                task: task,
                status: status,
                sortIndex: state.dropSortIndex(taskID, projectID: projectID, before: target, in: status)
            )
            return true
        }
        perform {
            try await state.dropTask(taskID, projectID: projectID, before: target, in: status)
        }
        return true
    }

    private func openChat(_ sessionID: String) {
        onOpenChat?(sessionID)
        if isModal { dismiss() }
    }
}
