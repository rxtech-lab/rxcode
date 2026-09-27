import Foundation
import RxCodeCore
import SwiftUI

// MARK: - Table layout

/// Spreadsheet-style list of tasks — GitHub's table layout.
struct TaskTableLayoutView: View {
    @Environment(AppState.self) private var appState

    let board: TaskBoard
    let view: TaskSavedView
    let tasks: [ProjectTask]
    let stories: [ProjectStory]
    let storyRollups: [UUID: StoryRollup]
    let onOpen: (TaskBoardSheet) -> Void
    let onAddStory: (TaskCreationMode) -> Void
    let onChangeStoryPanelStatuses: ([TaskStatus]) -> Void

    private static let taskPageSize = 80

    @State private var selection = Set<UUID>()
    @State private var pendingDeletion: TaskBoardSheet?
    @State private var sortOrder: [KeyPathComparator<TaskTableRow>] = []
    @State private var filters = TaskTableFilters()
    @State private var showingFilters = false
    @State private var visibleTaskCount = taskPageSize
    @State private var collapsedStoryIds = Set<UUID>()

    private var tableSortOrder: Binding<[KeyPathComparator<TaskTableRow>]> {
        Binding(get: { sortOrder }, set: {
            sortOrder = $0
            visibleTaskCount = Self.taskPageSize
        })
    }

    private var tableFilters: Binding<TaskTableFilters> {
        Binding(get: { filters }, set: {
            filters = $0
            visibleTaskCount = Self.taskPageSize
        })
    }

    var body: some View {
        let columns = view.visibleColumns(in: board.effectiveColumns)
        let visibleColumnIds = Set(columns.map(\.id))
        let columnStories = stories.filter {
            visibleColumnIds.contains(storyRollups[$0.id]?.status ?? board.rolledUpStatus(for: $0))
        }
        let panelStories = columnStories
            .filter { view.storyPanelShows(storyRollups[$0.id]?.status ?? board.rolledUpStatus(for: $0)) }
            .sorted {
                let lhs = board.columnIndex(of: storyRollups[$0.id]?.status ?? board.rolledUpStatus(for: $0))
                let rhs = board.columnIndex(of: storyRollups[$1.id]?.status ?? board.rolledUpStatus(for: $1))
                return lhs == rhs ? $0.updatedAt > $1.updatedAt : lhs < rhs
            }
        let completedStoryIds = Set(storyRollups.compactMap { id, rollup in
            rollup.progress.total > 0 && rollup.progress.done == rollup.progress.total ? id : nil
        })
        let collapsedVisibleStoryIds = collapsedStoryIds
            .intersection(Set(panelStories.map(\.id)))
            .intersection(completedStoryIds)
        let tableTasks = tasks.filter { task in
            !(task.storyId.map(collapsedVisibleStoryIds.contains) ?? false)
        }
        let page = taskPage(for: tableTasks)

        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Text("\(page.rows.count) of \(page.matchingCount) tasks")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Spacer()
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filter Columns", systemImage: filters.isEmpty
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .tint(filters.isEmpty ? nil : ClaudeTheme.accent)
                    .help("Filter the table by any column")
                    .accessibilityIdentifier("task-table-filter-columns")
                }
                .padding(.horizontal, 16)

                taskTable(page)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TaskStoriesPanel(
                stories: panelStories,
                board: board,
                storyRollups: storyRollups,
                filterColumns: columns,
                filterStatuses: view.storyPanelStatuses,
                onChangeFilter: onChangeStoryPanelStatuses,
                onOpen: onOpen,
                onAddStory: onAddStory,
                collapsedStoryIds: $collapsedStoryIds
            )
        }
        .sheet(isPresented: $showingFilters) {
            TaskTableFilterSheet(filters: tableFilters, options: filterOptions())
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .task(let task, _) = candidate { appState.deleteTask(task) }
        }
        .onChange(of: completedStoryIds) { _, completed in
            collapsedStoryIds.formIntersection(completed)
        }
    }

    private func taskPage(for tasks: [ProjectTask]) -> TaskTablePage {
        let lookup = TaskTableRowLookup(board: board)
        if filters.isEmpty && sortOrder.isEmpty {
            return TaskTablePage(
                rows: tasks.prefix(visibleTaskCount).map { makeRow($0, lookup: lookup) },
                matchingCount: tasks.count
            )
        }
        let matching = tasks.map { makeRow($0, lookup: lookup) }.filter(filters.matches)
        let ordered = sortOrder.isEmpty ? matching : matching.sorted(using: sortOrder)
        return TaskTablePage(rows: Array(ordered.prefix(visibleTaskCount)), matchingCount: ordered.count)
    }

    private func filterOptions() -> TaskTableFilterOptions {
        let lookup = TaskTableRowLookup(board: board)
        let rows = tasks.map { makeRow($0, lookup: lookup) }
        func distinct(_ values: [String]) -> [String] {
            Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        var seenStatuses = Set<String>()
        return TaskTableFilterOptions(
            statuses: board.effectiveColumns.map(\.name).filter { seenStatuses.insert($0).inserted },
            types: distinct(board.itemTypes.map(\.name) + rows.map(\.type)),
            priorities: TaskPriority.allCases.map(\.displayNameText),
            stories: distinct(rows.map(\.story)),
            versions: distinct(rows.map(\.version)),
            milestones: distinct(rows.map(\.milestone)),
            tags: distinct(rows.flatMap(\.task.tags)),
            agents: distinct(rows.map(\.agent))
        )
    }

    /// Resolves everything a cell draws up front. Table cells are re-measured
    /// for automatic row heights whenever a row scrolls into view, so board
    /// lookups and color parsing inside cell bodies cost frames while scrolling.
    private func makeRow(_ task: ProjectTask, lookup: TaskTableRowLookup) -> TaskTableRow {
        let column = lookup.columnsById[task.status] ?? lookup.fallbackColumn
        let type = task.typeId.flatMap { lookup.typesById[$0] }
        return TaskTableRow(
            task: task,
            status: column.name,
            statusIndex: lookup.columnIndexById[column.id] ?? 0,
            statusIcon: column.systemImage,
            statusTint: column.tint,
            type: type?.name ?? "",
            typeTint: type?.tint,
            story: task.storyId.flatMap { lookup.storyTitles[$0] } ?? "",
            tagPills: task.tags.map { TaskTableTag(name: $0, tint: lookup.tagTints[$0] ?? ClaudeTheme.textSecondary) },
            agent: appState.taskAgentLabel(task.agent)
        )
    }

    private func taskTable(_ page: TaskTablePage) -> some View {
        let lastVisibleTaskId = page.rows.last?.id
        return Table(page.rows, selection: $selection, sortOrder: tableSortOrder) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.statusIcon)
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(row.statusTint)
                    Text(row.title.isEmpty ? String(localized: "Untitled task") : row.title)
                        .lineLimit(1)
                }
                .onAppear {
                    if row.id == lastVisibleTaskId && visibleTaskCount < page.matchingCount {
                        visibleTaskCount = min(visibleTaskCount + Self.taskPageSize, page.matchingCount)
                    }
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Status", value: \.statusSortKey) { row in
                Text(row.status)
                    .foregroundStyle(row.statusTint)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Type", value: \.type) { row in
                if let typeTint = row.typeTint {
                    TaskPill(text: row.type, icon: "circle.fill", tint: typeTint)
                }
            }
            .width(min: 60, ideal: 90)

            TableColumn("Priority", value: \.prioritySortKey) { row in
                if let priority = row.task.priority {
                    Label {
                        Text(priority.displayName)
                    } icon: {
                        Image(systemName: priority.systemImage)
                    }
                    .foregroundStyle(priority.tint)
                }
            }
            .width(min: 60, ideal: 90)

            TableColumn("Story", value: \.story) { row in
                Text(row.story)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 160)

            TableColumn("Version", value: \.version) { row in
                if let version = row.task.version, !version.isEmpty {
                    TaskPill(text: version, icon: "tag", tint: ClaudeTheme.accent)
                }
            }
            .width(min: 60, ideal: 90)

            TableColumn("Milestone", value: \.milestone) { row in
                if let milestone = row.task.milestone, !milestone.isEmpty {
                    TaskPill(text: milestone, icon: "flag", tint: ClaudeTheme.statusSuccess)
                }
            }
            .width(min: 60, ideal: 100)

            TableColumn("Tags", value: \.tags) { row in
                HStack(spacing: 4) {
                    ForEach(row.tagPills) { TaskPill(text: $0.name, tint: $0.tint) }
                }
            }
            .width(min: 80, ideal: 180)

            TableColumn("Agent", value: \.agent) { row in
                Text(row.agent)
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
            if page.rows.isEmpty {
                Text("No tasks match this view.")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
    }
}

private struct TaskTablePage {
    let rows: [TaskTableRow]
    let matchingCount: Int
}

/// Board lookups built once per table render instead of once per cell.
private struct TaskTableRowLookup {
    let columnsById: [TaskStatus: TaskColumn]
    let columnIndexById: [TaskStatus: Int]
    let fallbackColumn: TaskColumn
    let typesById: [UUID: TaskItemType]
    let storyTitles: [UUID: String]
    let tagTints: [String: Color]

    init(board: TaskBoard) {
        let columns = board.effectiveColumns
        columnsById = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        columnIndexById = Dictionary(columns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        fallbackColumn = columns[0]
        typesById = Dictionary(board.effectiveTypes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        storyTitles = Dictionary(board.stories.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        tagTints = Dictionary(board.labels.map { ($0.name, Color(hex: $0.colorHex)) }, uniquingKeysWith: { first, _ in first })
    }
}

private struct TaskTableTag: Identifiable {
    let name: String
    let tint: Color

    var id: String { name }
}

private struct TaskTableRow: Identifiable {
    let task: ProjectTask
    let status: String
    let statusIndex: Int
    let statusIcon: String
    let statusTint: Color
    let type: String
    let typeTint: Color?
    let story: String
    let tagPills: [TaskTableTag]
    let agent: String

    var id: UUID { task.id }
    var title: String { task.title }
    var statusSortKey: String { String(format: "%04d %@", statusIndex, status) }
    var priority: String { task.priority?.displayNameText ?? "" }
    var prioritySortKey: String { "\(task.priority?.rank ?? TaskPriority.allCases.count) \(priority)" }
    var version: String { task.version ?? "" }
    var milestone: String { task.milestone ?? "" }
    var tags: String { task.tags.sorted().joined(separator: ", ") }
}

/// Column filters for the table. `nil` means "any value"; an empty string
/// matches rows with no value in that column.
private struct TaskTableFilters {
    var title = ""
    var status: String?
    var type: String?
    var priority: String?
    var story: String?
    var version: String?
    var milestone: String?
    var tags = Set<String>()
    var agent: String?

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [status, type, priority, story, version, milestone, agent].allSatisfy { $0 == nil }
            && tags.isEmpty
    }

    func matches(_ row: TaskTableRow) -> Bool {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (query.isEmpty || row.title.localizedStandardContains(query))
            && equals(row.status, status)
            && equals(row.type, type)
            && equals(row.priority, priority)
            && equals(row.story, story)
            && equals(row.version, version)
            && equals(row.milestone, milestone)
            && (tags.isEmpty || !tags.isDisjoint(with: row.task.tags))
            && equals(row.agent, agent)
    }

    private func equals(_ value: String, _ selected: String?) -> Bool {
        selected.map { $0 == value } ?? true
    }
}

/// Values offered by each filter dropdown, taken from the board and the
/// tasks currently in the view.
private struct TaskTableFilterOptions {
    var statuses: [String] = []
    var types: [String] = []
    var priorities: [String] = []
    var stories: [String] = []
    var versions: [String] = []
    var milestones: [String] = []
    var tags: [String] = []
    var agents: [String] = []
}

private struct TaskTableFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: TaskTableFilters
    let options: TaskTableFilterOptions

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $filters.title, prompt: Text("Contains…"))
                } header: {
                    Text("Search")
                }

                Section {
                    filterPicker("Status", selection: $filters.status, values: options.statuses, allowsNone: false)
                    filterPicker("Type", selection: $filters.type, values: options.types)
                    filterPicker("Priority", selection: $filters.priority, values: options.priorities)
                    filterPicker("Story", selection: $filters.story, values: options.stories)
                    filterPicker("Version", selection: $filters.version, values: options.versions)
                    filterPicker("Milestone", selection: $filters.milestone, values: options.milestones)
                    filterPicker("Agent", selection: $filters.agent, values: options.agents, allowsNone: false)
                } header: {
                    Text("Columns")
                }

                Section {
                    if options.tags.isEmpty {
                        Text("No tags in this view.")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    } else {
                        ForEach(options.tags, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(
                                get: { filters.tags.contains(tag) },
                                set: { isOn in
                                    if isOn { filters.tags.insert(tag) } else { filters.tags.remove(tag) }
                                }
                            ))
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Shows tasks with any selected tag. Active filters are combined.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Clear All") { filters = TaskTableFilters() }
                    .disabled(filters.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 430, height: 600)
    }

    private func filterPicker(
        _ title: LocalizedStringKey,
        selection: Binding<String?>,
        values: [String],
        allowsNone: Bool = true
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(String?.none)
            if allowsNone {
                Text("None").tag(String?.some(""))
            }
            if !values.isEmpty {
                Divider()
            }
            ForEach(values, id: \.self) { value in
                Text(value).tag(String?.some(value))
            }
        }
    }
}
