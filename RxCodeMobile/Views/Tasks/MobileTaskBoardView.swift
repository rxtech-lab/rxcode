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

    private var project: Project? {
        state.taskProjects.first { $0.id == projectID }
    }

    private var board: TaskBoard {
        state.taskBoard(for: projectID)
    }

    private var views: [TaskSavedView] { board.effectiveViews }

    private var currentView: TaskSavedView {
        views.first { $0.id == selectedViewID } ?? views.first ?? .defaultView
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
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("Filter tasks"))
        .overlay { overlayContent }
        .toolbar { toolbarContent }
        .modifier(MobileTaskDestinations(isEnabled: isModal, onOpenChat: openChat))
        .task(id: state.taskSyncReloadKey) {
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
        .mobileTaskErrorAlert($errorMessage)
    }

    @ViewBuilder
    private var boardContent: some View {
        if isRegularWidth && mode == .tasks && currentView.layout == .board {
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
                NavigationLink(value: MobileTaskRoute.task(projectID: projectID, taskID: task.id)) {
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
                NavigationLink(value: MobileTaskRoute.task(projectID: projectID, taskID: task.id)) {
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
                            NavigationLink(value: MobileTaskRoute.task(projectID: projectID, taskID: task.id)) {
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
                NavigationLink(value: MobileTaskRoute.story(projectID: projectID, storyID: story.id)) {
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
    private var overlayContent: some View {
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
                    Button { selectedViewID = view.id } label: {
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
            } label: {
                Label(currentView.name, systemImage: currentView.layout.systemImage)
            }
            .disabled(!hasLoaded)
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
              board.tasks.contains(where: { $0.id == taskID })
        else { return false }
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

private struct MobileViewEditorPayload: Identifiable {
    let view: TaskSavedView
    var id: UUID { view.id }
}

private struct MobileTaskViewForm: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    let onSave: (TaskSavedView) -> Void
    @State private var draft: TaskSavedView
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(projectID: UUID, view: TaskSavedView, onSave: @escaping (TaskSavedView) -> Void) {
        self.projectID = projectID
        self.onSave = onSave
        _draft = State(initialValue: view)
    }

    private var board: TaskBoard { state.taskBoard(for: projectID) }

    var body: some View {
        Form {
            Section("View") {
                TextField("Name", text: $draft.name)
                Picker("Layout", selection: $draft.layout) {
                    ForEach(TaskViewLayout.allCases, id: \.self) { layout in
                        Label { Text(layout.displayName) } icon: { Image(systemName: layout.systemImage) }
                            .tag(layout)
                    }
                }
            }

            Section("Statuses") {
                ForEach(board.effectiveColumns) { column in
                    Toggle(column.name, isOn: statusBinding(column.id))
                }
            }

            Section {
                filterLink(
                    "Stories",
                    options: board.stories.map { ($0.id, $0.title) },
                    selection: $draft.storyIds
                )
                filterLink(
                    "Versions",
                    options: listed(board.allVersions, draft.versions),
                    selection: $draft.versions
                )
                filterLink(
                    "Milestones",
                    options: listed(board.allMilestones, draft.milestones),
                    selection: $draft.milestones
                )
                filterLink(
                    "Tags",
                    options: listed(board.allTags, draft.tags),
                    selection: $draft.tags
                )
            } header: {
                Text("Filters")
            } footer: {
                Text("Items match any selected story, version and milestone, and must carry every selected tag.")
            }
        }
        .navigationTitle("View")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    private func statusBinding(_ status: TaskStatus) -> Binding<Bool> {
        let columns = board.effectiveColumns
        return Binding(
            get: { draft.visibleColumns(in: columns).contains { $0.id == status } },
            set: { isOn in
                var selected = Set(draft.visibleColumns(in: columns).map(\.id))
                if isOn { selected.insert(status) } else { selected.remove(status) }
                guard !selected.isEmpty else { return }
                draft.statuses = selected.count == columns.count ? [] : columns.map(\.id).filter(selected.contains)
            }
        )
    }

    private func filterLink<Value: Hashable>(
        _ title: LocalizedStringKey,
        options: [(Value, String)],
        selection: Binding<[Value]>
    ) -> some View {
        NavigationLink {
            MobileFilterValuesList(title: title, options: options, selection: selection)
        } label: {
            LabeledContent(title) {
                Text(summary(of: selection.wrappedValue, in: options))
            }
        }
    }

    private func summary<Value: Hashable>(of selected: [Value], in options: [(Value, String)]) -> String {
        switch selected.count {
        case 0: return String(localized: "Any")
        case 1: return options.first { $0.0 == selected[0] }?.1 ?? String(localized: "1 selected")
        default: return String(localized: "\(selected.count) selected")
        }
    }

    /// The board's values plus any selected value no item uses anymore, so a
    /// stale selection stays visible and can be switched off.
    private func listed(_ values: [String], _ selected: [String]) -> [(String, String)] {
        (values + selected.filter { !values.contains($0) }).map { ($0, $0) }
    }

    private func save() {
        var saved = draft
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deleted stories can't be shown or unselected, so they don't persist.
        saved.storyIds.removeAll { board.story(id: $0) == nil }
        guard !saved.name.isEmpty else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await state.saveView(saved, projectID: projectID)
                onSave(saved)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Makes a task row draggable onto other rows and column headers. Agent-owned
/// tasks stay put, matching the desktop board.
struct MobileTaskDraggable: ViewModifier {
    let task: ProjectTask
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(task.id.uuidString) {
                Text(task.title.isEmpty ? String(localized: "Untitled Task") : task.title)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            content
        }
    }
}

enum MobileTaskRoute: Hashable {
    case board(UUID)
    case task(projectID: UUID, taskID: UUID)
    case story(projectID: UUID, storyID: UUID)
}

/// Registers the task board's push destinations on the enclosing stack.
/// Applied once per stack: by the dashboard root, or by a board presented in
/// its own sheet.
struct MobileTaskDestinations: ViewModifier {
    var isEnabled = true
    let onOpenChat: (String) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationDestination(for: MobileTaskRoute.self) { route in
                switch route {
                case .board(let projectID):
                    MobileTaskBoardView(projectID: projectID, onOpenChat: onOpenChat, isModal: false)
                case .task(let projectID, let taskID):
                    MobileTaskDetailView(projectID: projectID, taskID: taskID, onOpenChat: onOpenChat)
                case .story(let projectID, let storyID):
                    MobileStoryDetailView(projectID: projectID, storyID: storyID, onOpenChat: onOpenChat)
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Shared task actions

/// Swipe actions and the long-press menu for a task row, so the board and
/// the story detail offer the same verbs as the desktop's context menu.
struct MobileTaskActions: ViewModifier {
    @EnvironmentObject private var state: MobileAppState
    let task: ProjectTask
    let board: TaskBoard
    let onEdit: () -> Void
    let onOpenChat: (String) -> Void
    let onError: (String) -> Void

    private var isLocked: Bool { board.isStatusLocked(task) }

    private var canRun: Bool {
        !state.usesCloudTasks && task.agent.isAssigned && !board.column(for: task.status).triggersChat && board.firstChatColumn != nil
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if canRun {
                    Button {
                        perform { try await state.runTask(task) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .tint(.green)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    perform { try await state.deleteTask(task) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                if let sessionID = state.taskSessionID(task) {
                    Button {
                        onOpenChat(sessionID)
                    } label: {
                        Label("Open Chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
                if canRun {
                    Button {
                        perform { try await state.runTask(task) }
                    } label: {
                        Label("Run with Agent", systemImage: "play")
                    }
                }
                Menu {
                    ForEach(board.effectiveColumns) { column in
                        Button {
                            perform { try await state.moveTask(task, to: column.id) }
                        } label: {
                            Label(column.name, systemImage: column.systemImage)
                        }
                        .disabled(column.id == board.resolvedStatus(of: task))
                    }
                } label: {
                    Label("Move To", systemImage: "arrow.right.square")
                }
                .disabled(isLocked)
                Divider()
                Button(role: .destructive) {
                    perform { try await state.deleteTask(task) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

extension View {
    /// Presents a task-board error as an alert while `message` is non-nil.
    func mobileTaskErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Task Board Error",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// Multi-select checklist for one view filter condition.
private struct MobileFilterValuesList<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [(Value, String)]
    @Binding var selection: [Value]

    var body: some View {
        List {
            if options.isEmpty {
                Text("Nothing to filter by yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options, id: \.0) { value, label in
                    Button {
                        toggle(value)
                    } label: {
                        HStack {
                            Text(label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(value) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { selection = [] }
                }
            }
        }
    }

    private func toggle(_ value: Value) {
        if selection.contains(value) {
            selection.removeAll { $0 == value }
        } else {
            selection.append(value)
        }
    }
}
