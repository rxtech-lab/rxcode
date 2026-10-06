import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// The Tasks route — the app's landing surface.
///
/// Two levels, modelled on GitHub Projects: an all-projects overview that
/// groups each project's recent stories and tasks, and a per-project page
/// with customizable board/table views. Which one shows is
/// `WindowState.taskDetailProjectId`.
struct TaskBoardView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    @State private var sheet: TaskBoardSheet?
    @State private var isContentReady = false

    private var detailProject: Project? {
        guard let id = windowState.taskDetailProjectId else { return nil }
        return appState.projects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if appState.projects.isEmpty {
                emptyProjectsState
            } else if !isContentReady {
                ProgressView(detailProject == nil ? "Loading projects…" : "Loading project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(detailProject == nil ? "task-overview-loading" : "task-project-loading")
            } else if let detailProject {
                TaskProjectDetailView(project: detailProject, sheet: $sheet)
                    .id(detailProject.id)
            } else {
                TaskOverviewView(sheet: $sheet)
            }
        }
        .background(ClaudeTheme.background)
        .task {
            // Give the navigation change a frame to paint before constructing
            // the project cards or detail page. The boards are loaded at launch.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            isContentReady = true
        }
        .onChange(of: windowState.taskDetailProjectId, initial: true) { _, projectId in
            guard let projectId else { return }
            appState.focusProject(id: projectId, in: windowState)
        }
        .sheet(item: $sheet) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: defaultProjectId)
                .environment(appState)
                .environment(windowState)
        }
    }

    /// The project a newly-created item belongs to when its payload names a
    /// project that no longer exists.
    private var defaultProjectId: UUID {
        windowState.taskDetailProjectId
            ?? windowState.selectedProject?.id
            ?? appState.projects.first?.id
            ?? UUID()
    }

    private var emptyProjectsState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: ClaudeTheme.size(26)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No projects yet")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text("Add a project to start tracking tasks.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Button {
                windowState.newProjectPrefersCloud = false
                windowState.showNewProjectSheet = true
            } label: {
                Label("New Project", systemImage: "plus.rectangle.on.folder")
            }
            .buttonStyle(.glass)
            .padding(.top, 4)
            .accessibilityIdentifier("task-board-new-project")

            HiddenCloudProjectsMenu()
                .padding(.top, 4)

            let cloudProjects = appState.visibleUnopenedCloudProjects
            if !cloudProjects.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: TaskOverviewView.cardSpacing) {
                        ForEach(cloudProjects) { cloud in
                            CloudProjectCard(cloud: cloud)
                                .frame(width: TaskOverviewView.cardWidth)
                        }
                    }
                    .padding(16)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AnalyticsService.shared.log(.taskDashboardOpened)
        }
    }
}

// MARK: - Overview

/// Every project's stories, grouped by project. Each group shows the most
/// recently active stories; a story's tasks open in a sheet, and the full
/// board lives on the project page.
struct TaskOverviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    @Binding var sheet: TaskBoardSheet?
    @State private var keyword = ""
    /// The story whose task sheet is open.
    @State private var storySheet: ProjectStory?

    /// How many stories each project group shows before "View all".
    static let previewLimit = 10
    /// Every project card has the same width; cards sit in one row that
    /// scrolls horizontally, like GitHub Projects board columns.
    static let cardWidth: CGFloat = 360
    static let cardSpacing: CGFloat = 16

    private var newItemProjectId: UUID {
        windowState.selectedProject?.id ?? appState.projects.first?.id ?? UUID()
    }

    var body: some View {
        let visibleProjects = visibleProjects
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            TaskFilterField(text: $keyword)
                .padding([.horizontal, .top], 16)

            if visibleProjects.isEmpty {
                Text("No stories match “\(keyword)”.")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Horizontal only: each card fills the page height and scrolls
                // its own rows, like a GitHub Projects board column.
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                        ForEach(visibleProjects) { project in
                            TaskProjectSection(
                                project: project,
                                keyword: keyword,
                                sheet: $sheet,
                                storySheet: $storySheet
                            )
                                .frame(width: Self.cardWidth)
                                .frame(maxHeight: .infinity)
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }
                        // Cloud projects from other devices that have no
                        // folder on this Mac yet.
                        if keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                            ForEach(appState.visibleUnopenedCloudProjects) { cloud in
                                CloudProjectCard(cloud: cloud)
                                    .frame(width: Self.cardWidth)
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    // Filtering drops non-matching projects; the rest slide
                    // together instead of jumping.
                    .taskBoardAnimation(value: visibleProjects.map(\.id))
                }
                .defaultScrollAnchor(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(backdrop)
        .onAppear {
            AnalyticsService.shared.log(.taskDashboardOpened)
        }
        .sheet(item: $storySheet) { story in
            StoryTasksSheet(storyId: story.id, projectId: story.projectId)
                .environment(appState)
                .environment(windowState)
        }
    }

    /// A soft accent wash behind the cards so the glass has something to
    /// refract; a flat fill makes Liquid Glass read as a plain grey panel.
    private var backdrop: some View {
        ZStack {
            ClaudeTheme.background
            RadialGradient(
                colors: [ClaudeTheme.accent.opacity(0.14), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 700
            )
            RadialGradient(
                colors: [ClaudeTheme.statusRunning.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 600
            )
        }
        .ignoresSafeArea()
    }

    /// While filtering, projects with no match drop out so results stay dense.
    private var visibleProjects: [Project] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return appState.projects }
        return appState.projects.filter { !appState.recentStories(for: $0.id, keyword: trimmed).isEmpty }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tasks")
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text("All projects")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Spacer()

            HiddenCloudProjectsMenu()

            Menu {
                Button {
                    windowState.newProjectPrefersCloud = false
                    windowState.showNewProjectSheet = true
                } label: {
                    Label("New Project…", systemImage: "laptopcomputer")
                }
                Button {
                    windowState.newProjectPrefersCloud = true
                    windowState.showNewProjectSheet = true
                } label: {
                    Label("New Cloud Project…", systemImage: "icloud")
                }
                if appState.isSignedIn {
                    Divider()
                    Button {
                        Task { await appState.refreshCloudProjectsAndBoards() }
                    } label: {
                        Label("Refresh Cloud Projects", systemImage: "arrow.clockwise.icloud")
                    }
                }
            } label: {
                Label("Project", systemImage: "folder.badge.plus")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Create a project on this Mac or in the cloud")
            .accessibilityIdentifier("task-board-project-menu")

            Menu {
                TaskCreationMenuItems(
                    onNewTask: { openNewTask(mode: $0) },
                    onNewStory: { openNewStory(mode: $0) }
                )
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("New task or story, written with AI or in a form")
            .accessibilityIdentifier("task-board-add")
            .background {
                // Menu items don't register key equivalents, so keep ⇧⌘N on a hidden button.
                Button("") { openNewTask(mode: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func openNewStory(mode: TaskCreationMode?) {
        sheet = .story(ProjectStory(projectId: newItemProjectId, title: ""), mode: mode)
    }

    private func openNewTask(mode: TaskCreationMode?) {
        sheet = .task(ProjectTask(
            projectId: newItemProjectId,
            title: "",
            status: appState.taskBoard(for: newItemProjectId).firstColumn.id
        ), mode: mode)
    }
}

// MARK: - Story card

/// A story on the overview, as an interactive Liquid Glass card: title,
/// description, rolled-up status and child-task progress. Tapping opens the
/// story's task sheet.
struct StoryGlassCard: View {
    let story: ProjectStory
    let board: TaskBoard
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        let status = board.column(for: board.rolledUpStatus(for: story))
        let progress = board.progress(for: story)
        let isActive = progress.active > 0
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(story.tint)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(story.tint.opacity(0.15))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                            .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        let details = story.details.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !details.isEmpty {
                            // Stripped, not rendered: descriptions are Markdown
                            // and a two-line card preview has no room for block
                            // layout — raw syntax would just eat the preview.
                            Text(stripMarkdown(details))
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 0)
                    TaskPill(text: status.name, icon: status.systemImage, tint: status.tint)
                        .fixedSize()
                        .id(status.id)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                let pills = TaskClassificationPills(story: story, board: board)
                if pills.hasContent {
                    FlowLayout(spacing: 4) { pills }
                }

                StoryProgressBar(story: story, board: board)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: shape)
        .overlay(
            shape.strokeBorder(
                (board.firstChatColumn?.tint ?? ClaudeTheme.accent).opacity(isActive ? 0.45 : 0),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        )
        .scaleEffect(isHovering ? 1.012 : 1)
        .onHover { isHovering = $0 }
        .taskBoardAnimation(TaskBoardMotion.feedback, value: isHovering)
        .taskBoardAnimation(value: isActive)
        .accessibilityIdentifier("task-story-card-\(story.id.uuidString)")
    }
}

// MARK: - Project card drag

/// The drag payload of a project card on the overview.
///
/// A dedicated `Transferable`, like the column and view-tab drags: story cards
/// live inside the drop target, so the payloads have to be distinguishable by
/// type for a drop to mean only one thing.
struct TaskProjectTransfer: Codable, Sendable, Transferable {
    let projectId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rxCodeTaskProject)
    }
}

extension UTType {
    /// Declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    static let rxCodeTaskProject = UTType(exportedAs: "com.rxlab.RxCode.task-project")
}
