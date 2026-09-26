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
    /// Which tab the next new story or task opens on, set by the menu entry
    /// that asked for it. Cleared with the sheet so a later "+" gets the
    /// kind's own default back.
    @State private var newItemMode: TaskCreationMode?
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
                TaskProjectDetailView(project: detailProject, sheet: $sheet, newItemMode: $newItemMode)
                    .id(detailProject.id)
            } else {
                TaskOverviewView(sheet: $sheet, newItemMode: $newItemMode)
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
        .sheet(item: $sheet, onDismiss: { newItemMode = nil }) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: defaultProjectId, initialMode: newItemMode)
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @Binding var newItemMode: TaskCreationMode?
    @State private var keyword = ""
    /// The story whose task sheet is open.
    @State private var storySheet: ProjectStory?
    @State private var notionSheet: NotionSyncPayload?

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
                                newItemMode: $newItemMode,
                                storySheet: $storySheet
                            )
                                .frame(width: Self.cardWidth)
                                .frame(maxHeight: .infinity)
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
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
        .sheet(item: $storySheet) { story in
            StoryTasksSheet(storyId: story.id, projectId: story.projectId)
                .environment(appState)
                .environment(windowState)
        }
        .sheet(item: $notionSheet) { payload in
            NotionSyncSheet(projectId: payload.projectId)
                .environment(appState)
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

            Button {
                notionSheet = NotionSyncPayload(projectId: newItemProjectId)
            } label: {
                Label("Notion", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .help("Sync a project's task status to Notion, or import a Notion database into a project")
            .accessibilityIdentifier("task-board-notion")

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
        newItemMode = mode
        sheet = .story(ProjectStory(projectId: newItemProjectId, title: ""))
    }

    private func openNewTask(mode: TaskCreationMode?) {
        newItemMode = mode
        sheet = .task(ProjectTask(
            projectId: newItemProjectId,
            title: "",
            status: appState.taskBoard(for: newItemProjectId).firstColumn.id
        ))
    }
}

// MARK: - Project section

/// One project's card on the overview: a header that opens the project page,
/// and up to `TaskOverviewView.previewLimit` recently active stories. Tasks
/// show inside a story's sheet rather than on the card.
///
/// The header doubles as a drag handle and the whole card is a drop target, so
/// cards can be rearranged the way board columns and view tabs are.
private struct TaskProjectSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let project: Project
    let keyword: String
    @Binding var sheet: TaskBoardSheet?
    @Binding var newItemMode: TaskCreationMode?
    @Binding var storySheet: ProjectStory?

    @State private var isDropTargeted = false
    @State private var pendingDeletion: TaskBoardSheet?

    private var board: TaskBoard { appState.taskBoard(for: project.id) }

    var body: some View {
        let stories = appState.recentStories(for: project.id, keyword: keyword)
        let board = board
        VStack(alignment: .leading, spacing: 0) {
            header

            if stories.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    GlassEffectContainer(spacing: 10) {
                        LazyVStack(spacing: 10) {
                            ForEach(stories.prefix(TaskOverviewView.previewLimit)) { story in
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
                        // Stories are ordered by recent activity, so one that
                        // just moved glides to the top rather than teleporting.
                        .taskBoardAnimation(value: storySignature(stories, board: board))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .padding(.top, 2)
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity, alignment: .top)

                if stories.count > TaskOverviewView.previewLimit {
                    Button(action: openProject) {
                        HStack(spacing: 4) {
                            Text("View all \(stories.count) stories")
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
            }
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
            if case .story(let story) = candidate { appState.deleteStory(story) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(keyword.isEmpty ? "No stories yet." : "No stories match.")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            if keyword.isEmpty {
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

            Spacer(minLength: 8)

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
            Image(systemName: "chevron.right")
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    /// Per-status task counts, e.g. ○ 4  ◎ 2  ✓ 7.
    private var statusSummary: some View {
        let board = board
        var counts: [TaskStatus: Int] = [:]
        for task in board.tasks {
            counts[board.resolvedStatus(of: task), default: 0] += 1
        }
        return HStack(spacing: 8) {
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
        newItemMode = mode
        sheet = .story(ProjectStory(projectId: project.id, title: ""))
    }

    private func openNewTask(mode: TaskCreationMode?) {
        newItemMode = mode
        sheet = .task(ProjectTask(projectId: project.id, title: "", status: board.firstColumn.id))
    }

    /// Order plus the rolled-up status and progress each story card shows.
    private func storySignature(_ stories: [ProjectStory], board: TaskBoard) -> [String] {
        stories.prefix(TaskOverviewView.previewLimit).map { story in
            let progress = board.progress(for: story)
            return "\(story.id):\(board.rolledUpStatus(for: story).rawValue):\(progress.done)/\(progress.total)"
        }
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

/// The chip that follows the pointer while a project card is dragged.
private struct TaskProjectDragPreview: View {
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
