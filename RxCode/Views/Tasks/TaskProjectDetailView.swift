import RxCodeCore
import SwiftUI

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

                Button {
                    appState.startNewChat(inProject: project.id, window: windowState)
                } label: {
                    Label("New Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.bordered)
                .help("Start a new chat in this project")

                Button {
                    sheet = .story(ProjectStory(projectId: project.id, title: ""))
                } label: {
                    Label("New Story", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.bordered)

                Button {
                    sheet = .task(newTask(status: .pending))
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
                        onDelete: { delete(view) }
                    )
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
                onEditView: { viewEditor = TaskViewEditorPayload(projectId: project.id, view: view, isNew: false) }
            )
        case .table:
            TaskTableLayoutView(
                board: board,
                tasks: tasks.sorted {
                    let lhs = TaskStatus.allCases.firstIndex(of: $0.status) ?? 0
                    let rhs = TaskStatus.allCases.firstIndex(of: $1.status) ?? 0
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

    private func hide(_ status: TaskStatus, in view: TaskSavedView) {
        var updated = view
        let remaining = view.visibleStatuses.filter { $0 != status }
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

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: view.layout.systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            Text(view.name)
                .font(.system(size: ClaudeTheme.size(12), weight: isSelected ? .semibold : .medium))
                .lineLimit(1)

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu { menuItems }
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

    static let columnWidth: CGFloat = 320

    /// Shared across columns: a story and its tasks usually sit in different
    /// columns, and hovering either highlights the whole group.
    @State private var hoveredStoryId: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(view.visibleStatuses, id: \.self) { status in
                    TaskColumnView(
                        status: status,
                        tasks: tasks.filter { $0.status == status }.sorted { $0.sortIndex < $1.sortIndex },
                        stories: stories.filter { board.rolledUpStatus(for: $0) == status },
                        board: board,
                        onOpen: onOpen,
                        onAdd: { onAdd(status) },
                        onHide: view.visibleStatuses.count > 1 ? { onHideStatus(status) } : nil,
                        onEditView: onEditView,
                        hoveredStoryId: $hoveredStoryId
                    )
                    .frame(width: Self.columnWidth)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
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
                    TaskStatusIcon(status: task.status)
                    Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                        .lineLimit(1)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Status") { task in
                Text(task.status.displayName)
                    .foregroundStyle(task.status.tint)
            }
            .width(min: 90, ideal: 110)

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

            TableColumn("Tags") { task in
                HStack(spacing: 4) {
                    ForEach(task.tags, id: \.self) { TaskPill(text: $0) }
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
