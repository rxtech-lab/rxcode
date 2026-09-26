import RxCodeCore
import SwiftUI

/// The board's story panel: every story in the view, stacked in a full-height
/// pane on the board's trailing edge, apart from the task columns.
///
/// Stories used to sit inside the column matching their rolled-up status, at
/// the same level as task cards, which made them easy to mistake for tasks.
/// A story moves only as its tasks do, so it doesn't need a column slot; each
/// card names its rolled-up status instead. The panel collapses to a thin rail
/// so the columns can take the whole width.
struct TaskStoriesPanel: View {
    let stories: [ProjectStory]
    let board: TaskBoard
    let storyRollups: [UUID: StoryRollup]
    /// Columns the status filter offers — the view's visible ones.
    let filterColumns: [TaskColumn]
    /// The view's saved story status filter; empty shows every status.
    let filterStatuses: [TaskStatus]
    let onChangeFilter: ([TaskStatus]) -> Void
    let onOpen: (TaskBoardSheet) -> Void
    let onAddStory: (TaskCreationMode) -> Void
    @Binding var collapsedStoryIds: Set<UUID>

    static let expandedWidth: CGFloat = 280
    static let collapsedWidth: CGFloat = 40

    @AppStorage("taskBoardStoriesPanelExpanded") private var isExpanded = true
    @State private var isFilterPresented = false

    /// Statuses the filter currently shows, limited to the offered columns.
    /// An empty or stale saved filter shows them all.
    private var shownStatuses: Set<TaskStatus> {
        let offered = Set(filterColumns.map(\.id))
        let saved = Set(filterStatuses).intersection(offered)
        return saved.isEmpty ? offered : saved
    }

    private var isFiltering: Bool {
        shownStatuses.count < filterColumns.count
    }

    var body: some View {
        Group {
            if isExpanded {
                expanded
                    .transition(.opacity)
            } else {
                rail
                    .transition(.opacity)
            }
        }
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ClaudeTheme.surfacePrimary.opacity(0.6))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ClaudeTheme.borderSubtle)
                .frame(width: 1)
        }
        .taskBoardAnimation(value: isExpanded)
        .accessibilityIdentifier("task-stories-panel")
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 16)

            if stories.isEmpty {
                Text("No stories match the status filter")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 24)
                Spacer(minLength: 0)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(stories) { story in
                        let status = storyRollups[story.id]?.status ?? board.rolledUpStatus(for: story)
                        StoryCardView(
                            story: story,
                            progress: storyRollups[story.id]?.progress ?? board.progress(for: story),
                            board: board,
                            column: board.column(for: status),
                            isCollapsed: collapsedStoryIds.contains(story.id),
                            onToggleCollapse: { toggleCollapse(story.id) },
                            onOpen: { onOpen(.story(story)) },
                            onNewTask: { onOpen(.task($0)) }
                        )
                        .transition(TaskBoardMotion.card)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text("Stories")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            TaskCountBadge(count: stories.count)

            Spacer(minLength: 0)

            filterButton

            Menu {
                Button {
                    onAddStory(.ai)
                } label: {
                    Label("Create Story with AI", systemImage: TaskCreationMode.ai.systemImage)
                }
                Button {
                    onAddStory(.form)
                } label: {
                    Label("Create Story with Form", systemImage: TaskCreationMode.form.systemImage)
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a story")

            Button {
                isExpanded = false
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide stories")
            .accessibilityIdentifier("task-stories-panel-toggle")
        }
    }

    // MARK: - Filter

    private var filterButton: some View {
        Button {
            isFilterPresented.toggle()
        } label: {
            Image(systemName: isFiltering
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(isFiltering ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Filter stories by status")
        .accessibilityIdentifier("task-stories-panel-filter")
        .popover(isPresented: $isFilterPresented, arrowEdge: .bottom) {
            filterPopover
        }
    }

    private var filterPopover: some View {
        let shown = shownStatuses
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Show stories by status")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer(minLength: 12)
                Button("Show All") { onChangeFilter([]) }
                    .buttonStyle(.link)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .disabled(!isFiltering)
            }

            ForEach(filterColumns) { column in
                let isOn = shown.contains(column.id)
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { setStatus(column.id, shown: $0) }
                )) {
                    HStack(spacing: 6) {
                        TaskStatusIcon(column: column)
                        Text(column.name)
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                    }
                }
                .toggleStyle(.checkbox)
                // Unchecking the last status would read as "show all".
                .disabled(isOn && shown.count == 1)
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    private func setStatus(_ status: TaskStatus, shown isShown: Bool) {
        var shown = shownStatuses
        if isShown { shown.insert(status) } else { shown.remove(status) }
        guard !shown.isEmpty else { return }
        // Every offered status checked is the same as no filter.
        let ordered = filterColumns.map(\.id).filter(shown.contains)
        onChangeFilter(ordered.count == filterColumns.count ? [] : ordered)
    }

    // MARK: - Collapsed

    /// A thin rail that reopens the panel, keeping the story count in view.
    private var rail: some View {
        Button {
            isExpanded = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: ClaudeTheme.size(12)))
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                TaskCountBadge(count: stories.count)
                Text("Stories")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: 56)
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show stories")
        .accessibilityIdentifier("task-stories-panel-toggle")
    }

    private func toggleCollapse(_ id: UUID) {
        if collapsedStoryIds.contains(id) {
            collapsedStoryIds.remove(id)
        } else {
            collapsedStoryIds.insert(id)
        }
    }
}
