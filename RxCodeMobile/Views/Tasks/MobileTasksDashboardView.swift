import RxCodeCore
import RxCodeSync
import SwiftUI

/// Every project's task board at a glance: projects first, then work that
/// is running or needs attention across projects. On iPhone the projects are
/// list rows; on iPad they are side-by-side cards of recent stories, like the
/// Mac's Tasks overview. Tapping a project opens its board.
struct MobileTasksDashboardView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Opens a chat thread in the host.
    let onOpenChat: (String) -> Void

    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var hasLoadedAny: Bool {
        !state.taskBoardsByProject.isEmpty
    }

    /// Tasks whose agent is running or that were flagged for a person,
    /// across every project, newest first.
    private var activeTasks: [ProjectTask] {
        state.projects
            .flatMap { state.taskBoard(for: $0.id).tasks }
            .filter { state.isTaskAgentRunning($0) || $0.attentionReason != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                overview
            } else {
                list
            }
        }
        .navigationTitle("Tasks")
        .overlay {
            if state.projects.isEmpty {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder",
                    description: Text("Add a project on your Mac to plan its tasks here.")
                )
            } else if !hasLoadedAny && isLoading {
                ProgressView("Loading tasks…")
            }
        }
        .modifier(MobileTaskDestinations(onOpenChat: onOpenChat))
        .task(id: state.taskSyncReloadKey) {
            guard state.isTaskSyncReady else { return }
            await load()
        }
        .refreshable { await load() }
        .mobileTaskErrorAlert($errorMessage)
    }

    // MARK: - iPad overview

    private var overview: some View {
        let active = activeTasks
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(state.projects) { project in
                        MobileProjectTaskCard(project: project, keyword: searchText)
                            .frame(width: 340)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)

            if !active.isEmpty {
                Text("Active")
                    .font(.headline)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(active) { task in
                            NavigationLink(value: MobileTaskRoute.task(projectID: task.projectId, taskID: task.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(projectName(task.projectId))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    MobileTaskRow(task: task, board: state.taskBoard(for: task.projectId), showsColumn: true)
                                }
                                .frame(width: 280, alignment: .leading)
                                .padding(12)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $searchText, prompt: Text("Filter stories"))
    }

    // MARK: - iPhone list

    private var list: some View {
        List {
            Section("Projects") {
                ForEach(state.projects) { project in
                    NavigationLink(value: MobileTaskRoute.board(project.id)) {
                        MobileProjectTaskSummaryRow(
                            project: project,
                            snapshot: state.taskBoardsByProject[project.id]
                        )
                    }
                    .accessibilityIdentifier("tasks-dashboard-project-\(project.id.uuidString)")
                }
            }

            if !activeTasks.isEmpty {
                Section("Active") {
                    ForEach(activeTasks) { task in
                        let board = state.taskBoard(for: task.projectId)
                        NavigationLink(value: MobileTaskRoute.task(projectID: task.projectId, taskID: task.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(projectName(task.projectId))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                MobileTaskRow(task: task, board: board, showsColumn: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func projectName(_ id: UUID) -> String {
        state.projects.first { $0.id == id }?.name ?? ""
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let error = await state.loadAllTaskBoards() {
            errorMessage = error
        }
    }
}

/// A project's name with its board summarized as per-column counts and
/// overall progress.
struct MobileProjectTaskSummaryRow: View {
    @EnvironmentObject private var state: MobileAppState
    let project: Project
    let snapshot: MobileTaskBoardSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Agent running")
                }
            }
            if let board = snapshot?.board {
                if board.tasks.isEmpty {
                    Text("No tasks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    MobileStoryProgressBar(progress: progress(board))
                    FlowLayout(spacing: 4) {
                        ForEach(board.effectiveColumns) { column in
                            let count = board.tasks(in: column.id).count
                            if count > 0 {
                                TaskPill(text: "\(column.name) \(count)", icon: column.systemImage, tint: column.tint)
                            }
                        }
                        if !board.stories.isEmpty {
                            TaskPill(text: String(localized: "\(board.stories.count) stories"), icon: "rectangle.stack")
                        }
                    }
                }
            } else if state.loadingTaskBoardProjects.contains(project.id) || !state.isTaskSyncReady {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Couldn't load tasks. Pull to refresh.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var isRunning: Bool {
        snapshot?.board.tasks.contains { state.isTaskAgentRunning($0) } ?? false
    }

    /// Whole-board progress, using the same done / started split as a story.
    private func progress(_ board: TaskBoard) -> StoryProgress {
        let columns = board.effectiveColumns
        let chatStart = columns.firstIndex(where: \.triggersChat)
        var done = 0
        var active = 0
        for task in board.tasks {
            let index = board.columnIndex(of: board.resolvedStatus(of: task))
            if columns[index].countsAsDone {
                done += 1
            } else if let chatStart, index >= chatStart {
                active += 1
            }
        }
        return StoryProgress(done: done, active: active, total: board.tasks.count)
    }
}

/// One project on the iPad overview, like a project card on the Mac's Tasks
/// overview: the board summary, then the most recently active stories. The
/// full board is one tap away.
struct MobileProjectTaskCard: View {
    @EnvironmentObject private var state: MobileAppState
    let project: Project
    var keyword = ""

    /// How many stories the card lists, matching the Mac overview.
    private static let previewLimit = 10

    private var snapshot: MobileTaskBoardSnapshot? { state.taskBoardsByProject[project.id] }
    private var board: TaskBoard { state.taskBoard(for: project.id) }

    private var stories: [ProjectStory] {
        board.stories
            .filter { $0.matches(keyword: keyword) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Tasks outside any story, shown when the project has no stories yet.
    private var looseTasks: [ProjectTask] {
        board.tasks
            .filter { $0.storyId == nil && $0.matches(keyword: keyword) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: MobileTaskRoute.board(project.id)) {
                HStack(alignment: .top) {
                    MobileProjectTaskSummaryRow(project: project, snapshot: snapshot)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tasks-dashboard-project-\(project.id.uuidString)")

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if snapshot != nil {
                        if !stories.isEmpty {
                            let rollups = board.storyRollups()
                            ForEach(stories.prefix(Self.previewLimit)) { story in
                                NavigationLink(value: MobileTaskRoute.story(projectID: project.id, storyID: story.id)) {
                                    cardRow { MobileStoryRow(story: story, board: board, rollup: rollups[story.id]) }
                                }
                                .buttonStyle(.plain)
                            }
                        } else if !looseTasks.isEmpty {
                            ForEach(looseTasks.prefix(Self.previewLimit)) { task in
                                NavigationLink(value: MobileTaskRoute.task(projectID: project.id, taskID: task.id)) {
                                    cardRow { MobileTaskRow(task: task, board: board, showsColumn: true) }
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Text(keyword.isEmpty ? String(localized: "No stories yet") : String(localized: "No matches"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
