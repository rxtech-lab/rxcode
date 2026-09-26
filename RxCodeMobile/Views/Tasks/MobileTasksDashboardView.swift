import RxCodeCore
import RxCodeSync
import SwiftUI

/// Every project's task board at a glance. On iPhone the projects are
/// list rows; on iPad they are full-height cards in a horizontal scroller.
/// Tapping a project opens its board.
struct MobileTasksDashboardView: View {
    @Environment(MobileCloudState.self) private var cloud
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Opens a chat thread in the host.
    let onOpenChat: (String) -> Void

    @State private var searchText = ""
    @State private var showingNewProject = false
    @State private var projectName = ""
    @State private var creatingProject = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("mobile.tasks.projectOrder") private var savedProjectOrder = Data()

    private var hasLoadedAny: Bool {
        !state.taskSnapshots.isEmpty
    }

    private var orderedProjects: [Project] {
        let keys = (try? JSONDecoder().decode([String].self, from: savedProjectOrder)) ?? []
        let ranks = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return state.taskProjects.enumerated().sorted { lhs, rhs in
            let left = ranks[orderKey(for: lhs.element)] ?? Int.max
            let right = ranks[orderKey(for: rhs.element)] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    var body: some View {
        Group {
            if state.usesCloudTasks && !cloud.isSignedIn {
                ContentUnavailableView {
                    Label("Your Tasks", systemImage: "checklist")
                } description: {
                    Text("Sign in to manage your cloud projects while your Mac is offline.")
                } actions: {
                    Button("Sign In") { Task { await cloud.signIn() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(cloud.isSigningIn || cloud.isRestoring)
                    if cloud.isSigningIn || cloud.isRestoring { ProgressView() }
                    if let error = cloud.error { Text(error).foregroundStyle(.red) }
                }
            } else if UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular {
                // Keep the title compact above the project cards.
                overview
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                list
                    .refreshable { await load() }
            }
        }
        .navigationTitle("Tasks")
        .overlay {
            if state.taskProjects.isEmpty && (!state.usesCloudTasks || cloud.isSignedIn) {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder",
                    description: Text(state.usesCloudTasks ? "Create a project to plan its tasks here." : "Add a project on your Mac to plan its tasks here.")
                )
            } else if !hasLoadedAny && isLoading {
                ProgressView("Loading tasks…")
            }
        }
        .modifier(MobileTaskDestinations(onOpenChat: onOpenChat))
        .toolbar {
            if UIDevice.current.userInterfaceIdiom == .phone && orderedProjects.count > 1 {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            if state.usesCloudTasks && cloud.isSignedIn {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sign Out", role: .destructive) { Task { await cloud.signOut() } }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Project", systemImage: "folder.badge.plus") { showingNewProject = true }
                        .disabled(creatingProject)
                }
            }
        }
        .alert("New Project", isPresented: $showingNewProject) {
            TextField("Project name", text: $projectName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                creatingProject = true
                Task {
                    defer { creatingProject = false }
                    do {
                        try await cloud.createProject(name: projectName.trimmingCharacters(in: .whitespacesAndNewlines))
                        projectName = ""
                        await load()
                    } catch { errorMessage = error.localizedDescription }
                }
            }.disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task(id: "\(state.taskSyncReloadKey)|\(cloud.isSignedIn)") {
            guard state.isTaskSyncReady else { return }
            await load()
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    // MARK: - iPad overview

    private var overview: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(orderedProjects) { project in
                        MobileProjectTaskCard(project: project, keyword: searchText)
                            .frame(width: 340, height: max(proxy.size.height - 32, 0), alignment: .top)
                            .dropDestination(for: String.self) { items, _ in
                                guard let dragged = items.first,
                                      dragged.hasPrefix("task-project:"),
                                      let moved = UUID(uuidString: String(dragged.dropFirst("task-project:".count)))
                                else { return false }
                                return reorder(moving: moved, onto: project.id)
                            }
                    }
                }
                .padding(16)
                .animation(.snappy(duration: 0.3), value: orderedProjects.map(\.id))
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $searchText, prompt: Text("Filter stories"))
        .accessibilityIdentifier("tasks-ipad-overview")
    }

    // MARK: - iPhone list

    private var list: some View {
        List {
            Section("Projects") {
                ForEach(orderedProjects) { project in
                    NavigationLink(value: MobileTaskRoute.board(project.id)) {
                        MobileProjectTaskSummaryRow(
                            project: project,
                            snapshot: state.taskSnapshots[project.id]
                        )
                    }
                    .accessibilityIdentifier("tasks-dashboard-project-\(project.id.uuidString)")
                }
                .onMove { source, destination in
                    var projects = orderedProjects
                    projects.move(fromOffsets: source, toOffset: destination)
                    saveOrder(projects)
                }
            }
        }
    }

    private func orderKey(for project: Project) -> String {
        if let cloudId = project.cloudId { return "cloud:\(cloudId)" }
        return "local:\(project.id.uuidString)"
    }

    private func saveOrder(_ projects: [Project]) {
        withAnimation(.snappy(duration: 0.3)) {
            savedProjectOrder = (try? JSONEncoder().encode(projects.map(orderKey))) ?? Data()
        }
    }

    private func reorder(moving moved: UUID, onto target: UUID) -> Bool {
        guard let projects = orderedProjects.reordered(moving: moved, onto: target) else { return false }
        saveOrder(projects)
        return true
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let error = await state.loadAllTaskBoards(), !Task.isCancelled {
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

    private var snapshot: MobileTaskBoardSnapshot? { state.taskSnapshots[project.id] }
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
            .draggable("task-project:\(project.id.uuidString)")
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
            .accessibilityIdentifier("tasks-ipad-project-content-\(project.id.uuidString)")
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
