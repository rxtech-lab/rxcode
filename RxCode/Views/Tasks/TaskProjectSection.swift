import RxCodeCore
import SwiftUI

// MARK: - Project section

/// One project's card on the overview: a header that opens the project page,
/// and up to `TaskOverviewView.previewLimit` recently active stories unless a
/// card filter is active. Tasks show inside a story's sheet rather than on the
/// card. The stories and counts
/// are narrowed by the project's default view.
///
/// The header doubles as a drag handle and the whole card is a drop target, so
/// cards can be rearranged the way board columns and view tabs are.
struct TaskProjectSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let project: Project
    let keyword: String
    @Binding var sheet: TaskBoardSheet?
    @Binding var storySheet: ProjectStory?
    @AppStorage private var cardFilterData: Data

    @State private var isDropTargeted = false
    @State private var pendingDeletion: TaskBoardSheet?
    @State private var scriptFilterResult: (script: String, outcome: TaskFilterScriptEvaluator.Outcome)?
    @State private var isEvaluatingScriptFilter = false

    private var board: TaskBoard { appState.taskBoard(for: project.id) }

    init(
        project: Project,
        keyword: String,
        sheet: Binding<TaskBoardSheet?>,
        storySheet: Binding<ProjectStory?>
    ) {
        self.project = project
        self.keyword = keyword
        self._sheet = sheet
        self._storySheet = storySheet
        self._cardFilterData = AppStorage(wrappedValue: Data(), "taskOverviewFilter.\(project.id.uuidString)")
    }

    private var cardFilter: TaskSavedView {
        (try? JSONDecoder().decode(TaskSavedView.self, from: cardFilterData))
            ?? TaskSavedView(name: String(localized: "Overview"))
    }

    private var cardFilterBinding: Binding<TaskSavedView> {
        Binding(
            get: { cardFilter },
            set: { cardFilterData = (try? JSONEncoder().encode($0)) ?? Data() }
        )
    }

    private var availableStories: [ProjectStory] {
        appState.recentStories(for: project.id)
    }

    private var filteredStories: [ProjectStory] {
        let filter = cardFilter
        let scriptSelection = scriptFilterSelection
        return appState.recentStories(for: project.id, keyword: keyword).filter { story in
            filter.matches(story, rolledUpStatus: board.rolledUpStatus(for: story))
                && (scriptSelection?.storyIds.contains(story.id) ?? true)
        }
    }

    private var hasActiveFilter: Bool { !cardFilter.isEmpty || cardFilter.hasFilterScript }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            storyContent
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        // A dragged card lands in this card's slot. The payload is the card's
        // own type, so a story or task drag can never reorder projects.
        .taskDropHighlight(isDropTargeted, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        .dropDestination(for: TaskProjectTransfer.self) { items, _ in
            guard let dragged = items.first?.projectId, dragged != project.id else { return false }
            appState.reorderProject(dragged, onto: project.id)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityIdentifier("task-project-section-\(project.id.uuidString)")
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            if case .story(let story, _) = candidate { appState.deleteStory(story) }
        }
        .task(id: scriptFilterKey) { await runScriptFilter() }
    }

    @ViewBuilder
    private var storyContent: some View {
        let stories = filteredStories
        if stories.isEmpty {
            emptyState
            Spacer(minLength: 0)
        } else {
            let displayed = hasActiveFilter ? stories : Array(stories.prefix(TaskOverviewView.previewLimit))
            storyScroll(displayed)
            if !hasActiveFilter && stories.count > TaskOverviewView.previewLimit {
                viewAllButton(storyCount: stories.count)
            }
        }
    }

    private func storyScroll(_ stories: [ProjectStory]) -> some View {
        ScrollView {
            GlassEffectContainer(spacing: 10) {
                LazyVStack(spacing: 10) {
                    ForEach(stories) { story in
                        StoryGlassCard(story: story, board: board) {
                            storySheet = story
                        }
                        .contextMenu {
                            StoryContextMenuItems(
                                story: story,
                                onEdit: { sheet = .story(story) },
                                onDelete: { pendingDeletion = .story(story) },
                                onNewTask: { sheet = .task($0) }
                            )
                        }
                        .transition(TaskBoardMotion.card)
                    }
                }
                .taskBoardAnimation(value: storySignature(stories, board: board))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func viewAllButton(storyCount: Int) -> some View {
        Button(action: openProject) {
            HStack(spacing: 4) {
                Text("View all \(storyCount) stories")
                Image(systemName: "arrow.right")
            }
            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            .foregroundStyle(ClaudeTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stories the default view filters out still exist.
            let hiddenByView = keyword.isEmpty && !board.stories.isEmpty
            Text(!keyword.isEmpty ? "No stories match." : !cardFilter.isEmpty || cardFilter.hasFilterScript ? "No stories match this filter." : hiddenByView ? "No stories in the default view." : "No stories yet.")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            if keyword.isEmpty && !hiddenByView {
                Button {
                    openNewStory(mode: nil)
                } label: {
                    Label("New Story", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            // The counts sit on their own line under the title: side by side
            // they squeeze the narrow card until a two-digit count wraps.
            VStack(alignment: .leading, spacing: 6) {
                // Only the title carries the drag: the add button and the menu
                // in the same row have to stay clickable. A tap gesture rather
                // than a `Button`, which swallows the drag, as the view tabs do.
                titleGroup
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openProject)
                    .draggable(TaskProjectTransfer(projectId: project.id)) {
                        TaskProjectDragPreview(project: project)
                    }
                    .accessibilityAddTraits(.isButton)
                    .help("Open the project's task views — drag onto another card to reorder")

                // Never compressed: a squeezed row clips the digits instead of
                // dropping a count.
                statusSummary
                    .fixedSize()
            }
            // The name takes the room it needs before the spacer and the
            // buttons; it only truncates when it truly doesn't fit.
            .layoutPriority(1)

            Spacer(minLength: 8)

            ProjectCloudButton(project: project, compact: true)

            TaskOverviewStoryFilter(
                projectId: project.id,
                stories: availableStories,
                board: board,
                filter: cardFilterBinding,
                isEvaluatingScript: isEvaluatingScriptFilter,
                scriptError: scriptFilterError
            )

            Menu {
                TaskCreationMenuItems(
                    onNewTask: { openNewTask(mode: $0) },
                    onNewStory: { openNewStory(mode: $0) }
                )
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New task or story in this project")
            .accessibilityIdentifier("task-overview-project-add")

            Menu {
                Button("Open Project Board", action: openProject)
                Divider()
                TaskCreationMenuItems(
                    onNewTask: { openNewTask(mode: $0) },
                    onNewStory: { openNewStory(mode: $0) }
                )
                Divider()
                Button("New Chat") { appState.startNewChat(inProject: project.id, window: windowState) }
                Divider()
                ProjectCloudMenuItems(project: project)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Folder icon, project name and the disclosure chevron — also the card's
    /// drag handle.
    private var titleGroup: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(project.name)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Image(systemName: "chevron.right")
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    /// Per-status task counts in the default view, e.g. ○ 4  ◎ 2  ✓ 7, led
    /// by the view's name once the project has more than one view.
    private var statusSummary: some View {
        let board = board
        let view = board.defaultView
        var counts: [TaskStatus: Int] = [:]
        for task in board.tasks(matching: view) {
            counts[board.resolvedStatus(of: task), default: 0] += 1
        }
        return HStack(spacing: 8) {
            if board.effectiveViews.count > 1 {
                Label(view.name, systemImage: view.layout.systemImage)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
                    .help("Default view")
            }
            ForEach(board.effectiveColumns) { column in
                let count = counts[column.id, default: 0]
                if count > 0 {
                    HStack(spacing: 3) {
                        TaskStatusIcon(column: column, size: 10)
                        Text("\(count)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func openProject() {
        windowState.taskDetailProjectId = project.id
    }

    private func openNewStory(mode: TaskCreationMode?) {
        sheet = .story(ProjectStory(projectId: project.id, title: ""), mode: mode)
    }

    private func openNewTask(mode: TaskCreationMode?) {
        sheet = .task(ProjectTask(projectId: project.id, title: "", status: board.firstColumn.id), mode: mode)
    }

    /// Order plus the rolled-up status and progress each story card shows.
    private func storySignature(_ stories: [ProjectStory], board: TaskBoard) -> [String] {
        stories.map { story in
            let progress = board.progress(for: story)
            return "\(story.id):\(board.rolledUpStatus(for: story).rawValue):\(progress.done)/\(progress.total)"
        }
    }

    private var scriptFilterKey: Int? {
        let filter = cardFilter
        guard filter.hasFilterScript, let script = filter.filterScript else { return nil }
        var hasher = Hasher()
        hasher.combine(script)
        hasher.combine(board.tasks)
        hasher.combine(board.stories)
        hasher.combine(board.effectiveColumns)
        hasher.combine(board.effectiveTypes)
        return hasher.finalize()
    }

    private var scriptFilterSelection: TaskFilterScript.Selection? {
        guard let result = scriptFilterResult,
              result.script == cardFilter.filterScript,
              case .selection(let selection) = result.outcome else { return nil }
        return selection
    }

    private var scriptFilterError: String? {
        guard let result = scriptFilterResult,
              result.script == cardFilter.filterScript,
              case .failure(let message) = result.outcome else { return nil }
        return message
    }

    private func runScriptFilter() async {
        let filter = cardFilter
        guard filter.hasFilterScript, let script = filter.filterScript else {
            isEvaluatingScriptFilter = false
            return
        }
        isEvaluatingScriptFilter = true
        let outcome = await appState.evaluateTaskFilterScript(script, projectId: project.id)
        guard !Task.isCancelled else { return }
        scriptFilterResult = (script, outcome)
        isEvaluatingScriptFilter = false
    }
}


/// The chip that follows the pointer while a project card is dragged.
struct TaskProjectDragPreview: View {
    let project: Project

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(project.name)
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ClaudeTheme.surfacePrimary, in: shape)
        .overlay(shape.strokeBorder(ClaudeTheme.border, lineWidth: 1))
    }
}
