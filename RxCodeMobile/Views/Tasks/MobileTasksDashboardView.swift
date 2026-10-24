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
    @State private var showingProjectCards = false
    @State private var openingProject: UUID?
    @State private var feedback: String?
    @State private var recentlyHidden: Project?
    @AppStorage("mobile.tasks.hiddenProjects") private var savedHiddenProjects = Data()
    @State private var creatingProject = false
    @State private var isLoading = false
    @State private var loadID = UUID()
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

    private var hiddenKeys: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: savedHiddenProjects)) ?? [])
    }

    private var visibleProjects: [Project] {
        orderedProjects.filter { !hiddenKeys.contains(visibilityKey(for: $0)) }
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
        .onAppear {
            AnalyticsService.shared.log(.taskDashboardOpened)
        }
        .overlay {
            if !hasLoadedAny && isLoading {
                ProgressView("Loading tasks…")
            } else if state.taskProjects.isEmpty && (!state.usesCloudTasks || cloud.isSignedIn) {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder",
                    description: Text(state.usesCloudTasks ? "Create a project to plan its tasks here." : "Add a project on your Mac to plan its tasks here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !orderedProjects.isEmpty && visibleProjects.isEmpty {
                ContentUnavailableView {
                    Label("All Project Cards Hidden", systemImage: "eye.slash")
                } description: {
                    Text("Restore cards from Project Cards.")
                } actions: {
                    Button("Project Cards") { openProjectCards() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let feedback {
                HStack {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                    if let recentlyHidden {
                        Button("Undo") { setHidden(false, project: recentlyHidden) }
                    }
                }
                .font(.callout)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
                .accessibilityIdentifier("tasks-project-card-status")
            }
        }
        .task(id: feedback) {
            guard feedback != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            feedback = nil
            recentlyHidden = nil
        }
        .navigationDestination(item: $openingProject) { id in
            MobileTaskBoardView(projectID: id, onOpenChat: onOpenChat, isModal: false)
        }
        .modifier(MobileTaskDestinations(onOpenChat: onOpenChat))
        .toolbar { projectToolbar }
        .sheet(isPresented: $showingNewProject) {
            FlowcyProjectForm { await load() }
                .mobileSheetPresentation()
        }
        .sheet(isPresented: $showingProjectCards) {
            MobileProjectCardsSheet(projects: orderedProjects,
                                    isHidden: { hiddenKeys.contains(visibilityKey(for: $0)) },
                                    setHidden: { hidden, project in setHidden(hidden, project: project) },
                                    reorder: saveOrder)
                .mobileSheetPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowcyDashboardChanged)) { _ in
            Task { await load() }
        }
        .task(id: "\(state.taskSyncReloadKey)|\(cloud.isSignedIn)") {
            state.restoreCloudTaskCacheIfNeeded()
            guard state.isTaskSyncReady else { return }
            await load()
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    @ToolbarContentBuilder
    private var projectToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Project Cards", systemImage: "rectangle.stack") { openProjectCards() }
                .accessibilityIdentifier("tasks-project-cards")
        }
        if state.usesCloudTasks && cloud.isSignedIn {
            ToolbarItem(placement: .primaryAction) {
                Button("New Project", systemImage: "folder.badge.plus") { showingNewProject = true }
                    .disabled(creatingProject)
            }
        }
    }

    // MARK: - iPad overview

    private var overview: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(visibleProjects) { project in
                        MobileProjectTaskCard(project: project, keyword: searchText, onOpen: {
                            MobileHaptics.buttonTap()
                            openingProject = project.id
                        }, onHide: { setHidden(true, project: project) }, onOpenChat: onOpenChat)
                            .frame(width: 340, height: max(proxy.size.height - 32, 0), alignment: .top)
                            .mobileLegacyDrop { items, _ in
                                guard let dragged = items.first,
                                      dragged.hasPrefix("task-project:"),
                                      let moved = UUID(uuidString: String(dragged.dropFirst("task-project:".count)))
                                else { return false }
                                return reorder(moving: moved, onto: project.id)
                            }
                            .mobileReorderItem()
                    }
                    .mobileReorderable()
                }
                .mobileReorderContainer(for: Project.self, move: reorderProjects)
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
                ForEach(visibleProjects) { project in
                    HStack {
                        MobileProjectTaskSummaryRow(
                            project: project,
                            snapshot: state.taskSnapshots[project.id]
                        )
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        MobileHaptics.buttonTap()
                        openingProject = project.id
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("tasks-dashboard-project-\(project.id.uuidString)")
                    .swipeActions {
                        Button("Hide Project Card", systemImage: "eye.slash") { setHidden(true, project: project) }
                    }
                    .mobileReorderItem()
                }
                // Let List commit its native row moves directly to the saved order.
                .onMove { source, destination in
                    var visible = visibleProjects
                    visible.move(fromOffsets: source, toOffset: destination)
                    var iterator = visible.makeIterator()
                    // Keep hidden cards in their saved slots while moving visible rows.
                    saveOrder(orderedProjects.map { project in
                        hiddenKeys.contains(visibilityKey(for: project)) ? project : (iterator.next() ?? project)
                    })
                }
            }
        }
    }

    private func reorderProjects(_ sources: [UUID], before target: UUID?) {
        guard let visible = mobileReordered(visibleProjects, moving: sources, before: target) else { return }
        var iterator = visible.makeIterator()
        saveOrder(orderedProjects.map { project in
            hiddenKeys.contains(visibilityKey(for: project)) ? project : (iterator.next() ?? project)
        })
    }

    private func orderKey(for project: Project) -> String {
        if let cloudId = project.cloudId { return "cloud:\(cloudId)" }
        return "local:\(project.id.uuidString)"
    }

    private func visibilityKey(for project: Project) -> String {
        if let cloudID = project.cloudId { return "cloud:\(cloud.accountID ?? "signed-in"):\(cloudID)" }
        return "local:\(project.id.uuidString)"
    }

    private func openProjectCards() {
        MobileHaptics.buttonTap()
        showingProjectCards = true
    }

    private func setHidden(_ hidden: Bool, project: Project) {
        var keys = hiddenKeys
        if hidden { keys.insert(visibilityKey(for: project)) }
        else { keys.remove(visibilityKey(for: project)) }
        withAnimation(.snappy) {
            savedHiddenProjects = (try? JSONEncoder().encode(keys.sorted())) ?? Data()
        }
        MobileHaptics.buttonTap()
        recentlyHidden = hidden ? project : nil
        feedback = hidden ? "\(project.name) hidden" : "\(project.name) restored"
    }

    private func saveOrder(_ projects: [Project]) {
        MobileHaptics.buttonTap()
        recentlyHidden = nil
        feedback = "Project cards reordered"
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
        let current = UUID()
        loadID = current
        isLoading = true
        defer { if loadID == current { isLoading = false } }
        let error = await state.loadAllTaskBoards()
        guard loadID == current, !Task.isCancelled else { return }
        errorMessage = error
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
                    let view = board.defaultView
                    let tasks = board.tasks(matching: view)
                    let storyCount = board.stories(matching: view).count
                    MobileStoryProgressBar(progress: progress(board, tasks: tasks))
                    FlowLayout(spacing: 4) {
                        if board.effectiveViews.count > 1 {
                            TaskPill(text: view.name, icon: view.layout.systemImage)
                        }
                        ForEach(board.effectiveColumns) { column in
                            let count = tasks.filter { board.resolvedStatus(of: $0) == column.id }.count
                            if count > 0 {
                                TaskPill(text: "\(column.name) \(count)", icon: column.systemImage, tint: column.tint)
                            }
                        }
                        if storyCount > 0 {
                            TaskPill(text: String(localized: "\(storyCount) stories"), icon: "rectangle.stack")
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

    /// Progress of the default view's tasks, using the same done / started
    /// split as a story.
    private func progress(_ board: TaskBoard, tasks: [ProjectTask]) -> StoryProgress {
        let columns = board.effectiveColumns
        let chatStart = columns.firstIndex(where: \.triggersChat)
        var done = 0
        var active = 0
        for task in tasks {
            let index = board.columnIndex(of: board.resolvedStatus(of: task))
            if columns[index].countsAsDone {
                done += 1
            } else if let chatStart, index >= chatStart {
                active += 1
            }
        }
        return StoryProgress(done: done, active: active, total: tasks.count)
    }
}

/// One project on the iPad overview, like a project card on the Mac's Tasks
/// overview: the board summary, then the most recently active stories, both
/// narrowed by the project's default view. The full board is one tap away.
struct MobileProjectTaskCard: View {
    @EnvironmentObject private var state: MobileAppState
    let project: Project
    var keyword = ""
    let onOpen: () -> Void
    let onHide: () -> Void
    let onOpenChat: (String) -> Void

    /// How many stories the card lists, matching the Mac overview.
    private static let previewLimit = 10

    private var snapshot: MobileTaskBoardSnapshot? { state.taskSnapshots[project.id] }
    private var board: TaskBoard { state.taskBoard(for: project.id) }

    private var stories: [ProjectStory] {
        board.stories(matching: board.defaultView)
            .filter { $0.matches(keyword: keyword) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Tasks outside any story, shown when the project has no stories yet.
    private var looseTasks: [ProjectTask] {
        board.tasks(matching: board.defaultView)
            .filter { $0.storyId == nil && $0.matches(keyword: keyword) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                MobileProjectTaskSummaryRow(project: project, snapshot: snapshot)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .mobileLegacyDrag("task-project:\(project.id.uuidString)")
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the project board. Long press and drag to reorder.")
                    .accessibilityIdentifier("tasks-dashboard-project-\(project.id.uuidString)")
                Menu {
                    Button("Open Project Board", systemImage: "rectangle.split.3x1", action: onOpen)
                    Button("Hide Project Card", systemImage: "eye.slash", action: onHide)
                } label: {
                    Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                }
                .accessibilityLabel("Project Card Actions")
                .accessibilityIdentifier("tasks-project-actions-\(project.id.uuidString)")
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if snapshot != nil {
                        if !stories.isEmpty {
                            let rollups = board.storyRollups()
                            ForEach(stories.prefix(Self.previewLimit)) { story in
                                MobileTaskDetailButton(route: MobileTaskRoute.story(projectID: project.id, storyID: story.id), onOpenChat: onOpenChat) {
                                    cardRow { MobileStoryRow(story: story, board: board, rollup: rollups[story.id]) }
                                }
                                .buttonStyle(.plain)
                            }
                        } else if !looseTasks.isEmpty {
                            ForEach(looseTasks.prefix(Self.previewLimit)) { task in
                                MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: project.id, taskID: task.id), onOpenChat: onOpenChat) {
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
