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
    @State private var showingLabelManager = false
    @State private var columnEditor: TaskColumnEditorPayload?
    @State private var showingColumnManager = false

    private var board: TaskBoard { appState.taskBoard(for: project.id) }
    private var views: [TaskSavedView] { appState.taskViews(for: project.id) }

    private var currentView: TaskSavedView {
        let views = views
        return views.first { $0.id == selectedViewId } ?? views.first ?? .defaultView
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            viewTabs
            TaskFilterField(text: $keyword)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            content
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

                Spacer()

                Menu {
                    Button {
                        sheet = .task(newTask(status: board.firstColumn.id))
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }

                    Button {
                        sheet = .story(ProjectStory(projectId: project.id, title: ""))
                    } label: {
                        Label("New Story", systemImage: "square.stack.3d.up")
                    }

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
                } label: {
                    Label("New Task", systemImage: "plus")
                } primaryAction: {
                    sheet = .task(newTask(status: board.firstColumn.id))
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help("New task — click the arrow for stories, chats, columns and fields")
                .background {
                    // Menu items don't register key equivalents, so keep ⇧⌘N on a hidden button.
                    Button("") {
                        sheet = .task(newTask(status: board.firstColumn.id))
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
                        canDelete: views.count > 1,
                        onSelect: { selectedViewId = view.id },
                        onEdit: { viewEditor = TaskViewEditorPayload(projectId: project.id, view: view, isNew: false) },
                        onDuplicate: { duplicate(view) },
                        onDelete: { delete(view) },
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
        let tasks = board.tasks
            .filter { view.matches($0) && $0.matches(keyword: keyword) }
        switch view.layout {
        case .board:
            TaskBoardLayoutView(
                board: board,
                view: view,
                tasks: tasks,
                stories: board.stories.filter {
                    view.matches($0, rolledUpStatus: board.rolledUpStatus(for: $0)) && $0.matches(keyword: keyword)
                },
                onOpen: { sheet = $0 },
                onAdd: { sheet = .task(newTask(status: $0)) },
                onHideStatus: { hide($0, in: view) },
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

    // MARK: - Actions

    /// A draft pre-filled from the current view's filters, so a task created
    /// inside a filtered view shows up in it.
    private func newTask(status: TaskStatus) -> ProjectTask {
        let view = currentView
        return ProjectTask(
            projectId: project.id,
            storyId: view.storyId,
            title: "",
            status: status,
            version: view.version,
            tags: view.tags
        )
    }

    private func duplicate(_ view: TaskSavedView) {
        let copy = TaskSavedView(
            name: String(localized: "\(view.name) copy"),
            layout: view.layout,
            tags: view.tags,
            version: view.version,
            storyId: view.storyId,
            statuses: view.statuses
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
    let canDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
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

/// Horizontally scrolling fixed-width columns, one per visible status.
struct TaskBoardLayoutView: View {
    let board: TaskBoard
    let view: TaskSavedView
    let tasks: [ProjectTask]
    let stories: [ProjectStory]
    let onOpen: (TaskBoardSheet) -> Void
    let onAdd: (TaskStatus) -> Void
    let onHideStatus: (TaskStatus) -> Void
    let onEditView: () -> Void
    let onEditColumn: (TaskColumn) -> Void
    /// `(dragged, target)`: the dragged column takes the target's slot.
    let onReorderColumn: (TaskStatus, TaskStatus) -> Void
    let onAddColumn: () -> Void

    static let columnWidth: CGFloat = 320

    /// Shared across columns: a story and its tasks usually sit in different
    /// columns, and hovering either highlights the whole group.
    @State private var hoveredStoryId: UUID?

    /// Where every card and column sits. Animating on this — rather than
    /// wrapping each drop in `withAnimation` — also covers moves nobody
    /// dragged: an agent finishing, a trigger advancing a card, a sync.
    private var layoutSignature: [String] {
        view.visibleColumns(in: board.effectiveColumns).map { "c:\($0.id.rawValue)" }
            + tasks.map { "t:\($0.id):\(board.resolvedStatus(of: $0).rawValue):\($0.sortIndex)" }
            + stories.map { "s:\($0.id):\(board.rolledUpStatus(for: $0).rawValue)" }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                let columns = view.visibleColumns(in: board.effectiveColumns)
                ForEach(columns) { column in
                    TaskColumnView(
                        column: column,
                        tasks: tasks
                            .filter { board.resolvedStatus(of: $0) == column.id }
                            .sorted { $0.sortIndex < $1.sortIndex },
                        stories: stories.filter { board.rolledUpStatus(for: $0) == column.id },
                        board: board,
                        onOpen: onOpen,
                        onAdd: { onAdd(column.id) },
                        onHide: columns.count > 1 ? { onHideStatus(column.id) } : nil,
                        onEditView: onEditView,
                        onEditColumn: { onEditColumn(column) },
                        onReorder: { onReorderColumn($0, column.id) },
                        hoveredStoryId: $hoveredStoryId
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
            .taskBoardAnimation(value: layoutSignature)
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
                TaskContextMenuItems(task: task) { onOpen(.task(task)) }
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
    }
}
