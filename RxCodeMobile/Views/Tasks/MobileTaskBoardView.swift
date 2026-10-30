import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI

/// A project's task board: tasks grouped by column, and stories with their
/// rolled-up progress. Board layouts show horizontally scrolling Kanban columns
/// on both iPhone and iPad. The same board UI supports
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var taskCardNamespace
    let projectID: UUID
    /// Opens a chat thread in the host (after this board is dismissed).
    var onOpenChat: ((String) -> Void)?
    /// True when presented in its own sheet: shows Done, owns its navigation
    /// destinations, and dismisses itself before opening a chat. False when
    /// pushed inside the Tasks dashboard's stack.
    var isModal = true

    @State private var showingHiddenViews = false
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
    @State private var showingColumnOrder = false
    @State private var runRequest: MobileTaskRunRequest?
    @State private var taskMovesInFlight = 0
    @AppStorage(TaskColumnFilter.storageKey) private var savedColumnFilters = Data()
    @AppStorage("mobile.tasks.columnOrder") private var savedColumnOrders = Data()

    // Column arrangement is a mobile presentation preference, scoped to the
    // account (or paired Mac) and project. Board status semantics stay intact.
    private var columnOrderScope: String {
        let owner = state.usesCloudTasks ? state.taskCloud?.accountID ?? "cloud" : state.pairedDesktopPubkey
        return "\(owner)|\(project?.cloudId ?? projectID.uuidString)"
    }

    private var taskMenuInset: CGFloat {
        if #available(iOS 27.0, *) { 32 } else { 0 }
    }

    private var visibleColumns: [TaskColumn] {
        let columns = currentView.visibleColumns(in: board.effectiveColumns)
        let orders = (try? JSONDecoder().decode([String: [TaskStatus]].self, from: savedColumnOrders)) ?? [:]
        let ranks = Dictionary((orders[columnOrderScope] ?? []).enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        return columns.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    private func filterScope(_ column: TaskColumn) -> String {
        TaskColumnFilter.scope(project: columnOrderScope, viewID: currentView.id, columnID: column.id)
    }

    private func localFilter(_ column: TaskColumn) -> TaskColumnFilter {
        TaskColumnFilter.load(from: savedColumnFilters, scope: filterScope(column))
    }

    private func columnTasks(_ column: TaskColumn) -> [ProjectTask] {
        let filter = localFilter(column)
        return currentView.sort(for: column.id).sorted(board.tasks(in: column.id).filter {
            snapshotContains($0.id, story: false) && currentView.matches($0)
                && $0.matches(keyword: searchText) && filter.matches($0)
        })
    }

    private func columnOptions(_ column: TaskColumn) -> some View {
        TaskColumnOptionsButton(column: column, board: board, sort: currentView.sort(for: column.id), filterScope: filterScope(column)) { sort in
            var view = currentView
            view.columnSorts[column.id.rawValue] = sort
            try await state.saveView(view, projectID: projectID)
        }
    }

    private var project: Project? {
        state.taskProjects.first { $0.id == projectID }
    }

    private var board: TaskBoard {
        state.taskBoard(for: projectID)
    }

    private var views: [TaskSavedView] { board.visibleViews }

    /// The picked view, else the project's default view.
    private var currentView: TaskSavedView {
        views.first { $0.id == selectedViewID } ?? views.first(where: \.isDefault) ?? views.first ?? .defaultView
    }

    private func snapshotContains(_ id: UUID, story: Bool) -> Bool {
        guard currentView.hasFilterScript else { return true }
        guard let snapshot = currentView.filterSnapshot, snapshot.source == currentView.filterScript else { return false }
        return (story ? snapshot.stories : snapshot.tasks).contains { $0.caseInsensitiveCompare(id.uuidString) == .orderedSame }
    }

    private var visibleTasks: [ProjectTask] {
        board.tasks.filter { snapshotContains($0.id, story: false) && currentView.matches($0) && $0.matches(keyword: searchText) }
    }

    private var visibleStories: [ProjectStory] {
        board.stories.filter {
            snapshotContains($0.id, story: true) && currentView.matches($0, rolledUpStatus: board.rolledUpStatus(for: $0))
                && $0.matches(keyword: searchText)
        }
    }

    /// Track placement only, so polling metadata does not animate every card.
    private var taskCardLayout: [[UUID]] {
        visibleColumns.map { column in
            columnTasks(column).map(\.id)
        }
    }

    private var hasLoaded: Bool {
        state.taskSnapshots[projectID] != nil
    }

    /// iPad: columns side by side, with the view picker in the toolbar.
    private var isRegularWidth: Bool { UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular }

    var body: some View {
        boardContent
        .disabled(currentView.hasFilterScript)
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
            if !hasLoaded {
                boardStatusContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .topTrailing) {
            if taskMovesInFlight > 0 {
                ProgressView("Moving tasks…").padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            } else {
                TaskViewSaveFeedback(isSaving: isSavingView, feedback: viewFeedback)
            }
        }
        .task(id: viewFeedback) {
            guard viewFeedback != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            viewFeedback = nil
        }
        .modifier(MobileTaskDestinations(isEnabled: isModal, onOpenChat: openChat))
        .task(id: "\(state.taskSyncReloadKey)|\(scenePhase)") {
            state.restoreCloudTaskCacheIfNeeded()
            guard state.isTaskSyncReady, scenePhase == .active else { return }
            await load()
            while state.usesCloudTasks && !Task.isCancelled && errorMessage == nil {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled else { return }
                if editingView == nil && !isSavingView { await load() }
            }
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
        .sheet(isPresented: $showingHiddenViews) {
            TaskHiddenViewsSheet(views: board.effectiveViews, isSaving: isSavingView, feedback: viewFeedback,
                onRestore: { setHidden(false, view: $0) }, onDone: { MobileHaptics.buttonTap(); showingHiddenViews = false })
                .mobileTaskErrorAlert($errorMessage)
                .mobileSheetPresentation([.large])
        }
        .sheet(isPresented: $showingColumnOrder) {
            columnOrderSheet.mobileSheetPresentation([.medium, .large])
        }
        .mobileTaskRunDevicePicker($runRequest)
        .mobileTaskErrorAlert($errorMessage)
    }

    @ViewBuilder
    private var boardContent: some View {
        if hasLoaded && views.isEmpty {
            ContentUnavailableView("All Views Hidden", systemImage: "eye.slash",
                description: Text("Use Hidden Views to restore a view."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasLoaded && currentView.hasFilterScript && currentView.filterSnapshot?.source != currentView.filterScript {
            ContentUnavailableView("Waiting for Host Sync", systemImage: "desktopcomputer",
                description: Text("Open RxCode on your Mac to sync this Swift filter view."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasLoaded && (mode == .tasks ? visibleTasks.isEmpty : visibleStories.isEmpty) {
            VStack(spacing: 0) {
                if !isRegularWidth {
                    modePicker
                        .environment(\.isEnabled, true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                boardStatusContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-board-empty-state")
        } else if mode == .tasks && currentView.layout == .board {
            VStack(spacing: 0) {
                if !isRegularWidth {
                    modePicker
                        .environment(\.isEnabled, true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                kanbanBoard
                    .padding(.top, isRegularWidth ? 0 : 12)
            }
        } else {
            List {
                if !isRegularWidth {
                    Section {
                        modePicker
                        .environment(\.isEnabled, true)
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
            .mobileReorderContainer(for: ProjectTask.self, in: TaskStatus.self, move: reorderTasks)
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

    // MARK: - Kanban

    /// Scrolls horizontally only; each column fits the visible height and
    /// scrolls its own cards, so the last card is never cut off.
    private var kanbanBoard: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                // Keep column destinations alive for moves across the board.
                HStack(alignment: .top, spacing: 12) {
                    ForEach(visibleColumns) { column in
                        kanbanColumn(column, height: max(proxy.size.height, 0))
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: taskCardLayout)
        .clipped()
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("tasks-ipad-kanban")
    }

    private func kanbanColumn(_ column: TaskColumn, height: CGFloat) -> some View {
        let tasks = columnTasks(column)
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
                columnOptions(column)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("task-column-\(column.id.rawValue)")

        } cards: {
            if tasks.isEmpty {
                ContentUnavailableView("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Change this column’s filters or add a task."))
                    .frame(maxWidth: .infinity, minHeight: max(0, height - 80))
            }
            ForEach(tasks) { task in
                MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                    MobileTaskRow(task: task, board: board)
                        .padding(.trailing, taskMenuInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .matchedGeometryEffect(
                    id: task.id,
                    in: taskCardNamespace,
                    properties: reduceMotion ? [] : .frame
                )
                .transition(.identity)
                .modifier(MobileTaskActions(
                    task: task,
                    board: board,
                    onEdit: { editingTask = task },
                    onOpenChat: openChat,
                    onError: { errorMessage = $0 },
                    nativeReordering: true
                ))
                .modifier(MobileTaskDraggable(task: task, isEnabled: !board.isStatusLocked(task) && state.canEditCard(task)))
                .mobileLegacyDrop { items, _ in
                    drop(items, before: task, in: column.id)
                }
                .mobileReorderItem()
                .moveDisabled(board.isStatusLocked(task) || currentView.sort(for: column.id).field != .manual)
            }
            .mobileReorderable()
        }
        .frame(width: 300, height: height, alignment: .top)
        // Keep swiped cards and their actions inside the column.
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(column.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(column.tint.opacity(0.18)))
        .contentShape(Rectangle())
        .mobileTaskReorderContainer(status: column.id, move: reorderTasks)
        // Dropping anywhere else in the column appends to its end.
        .mobileLegacyDrop { items, _ in
            drop(items, before: nil, in: column.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-kanban-column-\(column.id.rawValue)")
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
        ForEach(visibleColumns) { column in
            let tasks = columnTasks(column)
            if !tasks.isEmpty || searchText.isEmpty || !localFilter(column).isEmpty {
                Section {
                    if !collapsedColumns.contains(column.id) {
                        ForEach(tasks) { task in
                            MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                                MobileTaskRow(task: task, board: board)
                                    .padding(.trailing, taskMenuInset)
                            }
                            .modifier(MobileTaskActions(
                                task: task,
                                board: board,
                                onEdit: { editingTask = task },
                                onOpenChat: openChat,
                                onError: { errorMessage = $0 },
                                nativeReordering: true
                            ))
                            .modifier(MobileTaskDraggable(task: task, isEnabled: !board.isStatusLocked(task) && state.canEditCard(task)))
                            .mobileLegacyDrop { items, _ in
                                drop(items, before: task, in: column.id)
                            }
                            .mobileReorderItem()
                            .moveDisabled(board.isStatusLocked(task) || currentView.sort(for: column.id).field != .manual)
                        }
                        .mobileReorderable(collectionID: column.id)
                    }
                } header: {
                    columnHeader(column, count: tasks.count)
                        .mobileLegacyDrop { items, _ in
                            drop(items, before: nil, in: column.id)
                        }
                }
            }
        }
    }

    private func columnHeader(_ column: TaskColumn, count: Int) -> some View {
        HStack {
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
        columnOptions(column)
        }
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
            MobileTaskViewPicker(views: views, currentView: currentView, defaultViewID: board.defaultView.id,
                canReorderColumns: visibleColumns.count > 1,
                onSelect: { selectedViewID = $0 },
                onShowHidden: { showingHiddenViews = true },
                onHide: { setHidden(true, view: currentView) },
                onReorderColumns: { showingColumnOrder = true },
                onCreate: { editingView = MobileViewEditorPayload(view: TaskSavedView(name: String(localized: "New view"))) },
                onEdit: { editingView = MobileViewEditorPayload(view: currentView) },
                onSetDefault: { setDefault(currentView) })
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
            .disabled(!hasLoaded || currentView.hasFilterScript)
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

    private func setHidden(_ hidden: Bool, view: TaskSavedView) {
        var updated = view
        updated.isHidden = hidden
        MobileHaptics.buttonTap()
        saveView(updated, feedback: hidden ? String(localized: "View hidden") : String(localized: "View restored"))
    }

    private func setDefault(_ view: TaskSavedView) {
        var updated = view
        updated.isDefault = true
        selectedViewID = view.id
        MobileHaptics.buttonTap()
        saveView(updated, feedback: String(localized: "Default view updated"))
    }

    private func saveView(_ view: TaskSavedView, feedback: String) {
        isSavingView = true
        Task {
            defer { isSavingView = false }
            do {
                try await state.saveView(view, projectID: projectID)
                if view.isHidden && selectedViewID == view.id { selectedViewID = nil }
                viewFeedback = feedback
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

    // A separate surface avoids competing native column and task drag scopes.
    private var columnOrderSheet: some View {
        NavigationStack {
            Group {
                if #available(iOS 27.0, *) {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleColumns) { column in
                                columnOrderRow(column)
                            }
                            .reorderable()
                        }
                        .padding()
                        .reorderContainer(for: TaskColumn.self) { difference in
                            switch difference.destination.position {
                            case .before(let id): reorderColumns(difference.sources, before: id)
                            case .end: reorderColumns(difference.sources, before: nil)
                            }
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        ForEach(visibleColumns) { column in
                            columnOrderRow(column)
                        }
                        .onMove { source, destination in
                            var columns = visibleColumns
                            columns.move(fromOffsets: source, toOffset: destination)
                            saveColumnOrder(columns)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .overlay {
                if visibleColumns.isEmpty {
                    ContentUnavailableView("No Columns", systemImage: "rectangle.split.3x1")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Reorder Columns")
            .navigationBarTitleDisplayMode(.inline)
            .mobileStatusToast($viewFeedback)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        MobileHaptics.buttonTap()
                        showingColumnOrder = false
                    }
                }
            }
        }
    }

    private func columnOrderRow(_ column: TaskColumn) -> some View {
        HStack {
            Label(column.name, systemImage: column.systemImage)
                .foregroundStyle(column.tint)
            Spacer()
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .mobileReorderItem()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reorder-column-\(column.id.rawValue)")
    }

    private func reorderColumns(_ sources: [TaskStatus], before target: TaskStatus?) {
        guard let columns = mobileReordered(visibleColumns, moving: sources, before: target) else { return }
        saveColumnOrder(columns)
    }

    private func saveColumnOrder(_ columns: [TaskColumn]) {
        var orders = (try? JSONDecoder().decode([String: [TaskStatus]].self, from: savedColumnOrders)) ?? [:]
        // Preserve filtered-out columns in their slots.
        let visibleIDs = Set(visibleColumns.map(\.id))
        let previous = orders[columnOrderScope] ?? board.effectiveColumns.map(\.id)
        var iterator = columns.map(\.id).makeIterator()
        orders[columnOrderScope] = previous.map { visibleIDs.contains($0) ? (iterator.next() ?? $0) : $0 }
        orders[columnOrderScope]?.append(contentsOf: Array(iterator))
        withAnimation(reduceMotion ? nil : .snappy) {
            savedColumnOrders = (try? JSONEncoder().encode(orders)) ?? Data()
        }
        MobileHaptics.buttonTap()
        viewFeedback = "Column order saved"
    }

    private func reorderTasks(_ sources: [UUID], before target: UUID?, in status: TaskStatus) {
        let isManual = currentView.sort(for: status).field == .manual
        let destination = isManual ? target.flatMap { id in board.tasks.first { $0.id == id } } : nil
        guard isManual || sources.allSatisfy({ id in
            board.tasks.first { $0.id == id }.map { board.resolvedStatus(of: $0) != status } ?? false
        }) else { return }
        guard !sources.isEmpty,
              board.effectiveColumns.contains(where: { $0.id == status }),
              !isManual || target == nil || destination.map({ board.resolvedStatus(of: $0) == status }) == true,
              !sources.contains(where: { $0 == target }),
              sources.allSatisfy({ id in
                  board.tasks.first { $0.id == id }.map { !board.isStatusLocked($0) } ?? false
              }) else { return }
        // Single-card moves retain the existing run-device picker.
        if sources.count == 1 {
            _ = drop([sources[0].uuidString], before: destination, in: status)
            return
        }
        // A run needs a separate device choice for each card.
        guard !sources.contains(where: { id in
            board.tasks.first { $0.id == id }.map { state.moveStartsRun($0, to: status) } ?? false
        }) else { return }
        moveTasks(sources, before: destination, in: status)
    }

    private func moveTasks(_ sources: [UUID], before target: ProjectTask?, in status: TaskStatus) {
        taskMovesInFlight += 1
        MobileHaptics.buttonTap()
        Task {
            defer { taskMovesInFlight -= 1 }
            do {
                // Apply multiple sources in order so their relative placement
                // doesn't depend on which network request finishes first.
                for id in sources {
                    try await state.dropTask(id, projectID: projectID, before: target, in: status)
                }
                viewFeedback = "Task order saved"
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Handles a task card dropped on a row (placed before it) or a column
    /// header (appended to the column).
    private func drop(_ items: [String], before target: ProjectTask?, in status: TaskStatus) -> Bool {
        guard !currentView.hasFilterScript else { return false }
        guard let taskID = items.first.flatMap(UUID.init(uuidString:)),
              let task = board.tasks.first(where: { $0.id == taskID })
        else { return false }
        guard task.id != target?.id, !board.isStatusLocked(task) else { return false }
        guard currentView.sort(for: status).field == .manual || board.resolvedStatus(of: task) != status else { return false }
        if state.moveStartsRun(task, to: status) {
            MobileHaptics.buttonTap()
            // Dropping into a run column asks which Mac runs it first.
            runRequest = MobileTaskRunRequest(
                task: task,
                status: status,
                sortIndex: state.dropSortIndex(taskID, projectID: projectID,
                    before: currentView.sort(for: status).field == .manual ? target : nil, in: status)
            )
            return true
        }
        moveTasks([taskID], before: currentView.sort(for: status).field == .manual ? target : nil, in: status)
        return true
    }

    private func openChat(_ sessionID: String) {
        onOpenChat?(sessionID)
        if isModal { dismiss() }
    }
}
