import RxCodeCore
import SwiftUI

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

    private var detailProject: Project? {
        guard let id = windowState.taskDetailProjectId else { return nil }
        return appState.projects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if appState.projects.isEmpty {
                emptyProjectsState
            } else if let detailProject {
                TaskProjectDetailView(project: detailProject, sheet: $sheet)
                    .id(detailProject.id)
            } else {
                TaskOverviewView(sheet: $sheet)
            }
        }
        .background(ClaudeTheme.background)
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
                    HStack(alignment: .top, spacing: Self.cardSpacing) {
                        ForEach(visibleProjects) { project in
                            TaskProjectSection(project: project, keyword: keyword, sheet: $sheet, storySheet: $storySheet)
                                .frame(width: Self.cardWidth)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
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
                sheet = .story(ProjectStory(projectId: newItemProjectId, title: ""))
            } label: {
                Label("New Story", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.bordered)

            Button {
                sheet = .task(ProjectTask(projectId: newItemProjectId, title: ""))
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Project section

/// One project's card on the overview: a header that opens the project page,
/// and up to `TaskOverviewView.previewLimit` recently active stories. Tasks
/// show inside a story's sheet rather than on the card.
private struct TaskProjectSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let project: Project
    let keyword: String
    @Binding var sheet: TaskBoardSheet?
    @Binding var storySheet: ProjectStory?

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
                                    StoryContextMenuItems(story: story) { sheet = .story(story) }
                                }
                            }
                        }
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
        .accessibilityIdentifier("task-project-section-\(project.id.uuidString)")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(keyword.isEmpty ? "No stories yet." : "No stories match.")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            if keyword.isEmpty {
                Button {
                    sheet = .story(ProjectStory(projectId: project.id, title: ""))
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
        HStack(spacing: 10) {
            Button(action: openProject) {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the project's task views")

            statusSummary

            Spacer(minLength: 8)

            Button {
                sheet = .story(ProjectStory(projectId: project.id, title: ""))
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New story in this project")

            Menu {
                Button("Open Project Board", action: openProject)
                Divider()
                Button("New Story") { sheet = .story(ProjectStory(projectId: project.id, title: "")) }
                Button("New Task") { sheet = .task(ProjectTask(projectId: project.id, title: "")) }
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

    /// Per-status task counts, e.g. ○ 4  ◎ 2  ✓ 7.
    private var statusSummary: some View {
        HStack(spacing: 8) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                let count = board.tasks.filter { $0.status == status }.count
                if count > 0 {
                    HStack(spacing: 3) {
                        TaskStatusIcon(status: status, size: 10)
                        Text("\(count)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func openProject() {
        windowState.taskDetailProjectId = project.id
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

    var body: some View {
        let status = board.rolledUpStatus(for: story)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(story.tint)
                    Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    TaskPill(text: status.displayNameText, tint: status.tint)
                        .fixedSize()
                }

                let details = story.details.trimmingCharacters(in: .whitespacesAndNewlines)
                if !details.isEmpty {
                    Text(details)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                StoryProgressBar(progress: board.progress(for: story))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        .accessibilityIdentifier("task-story-card-\(story.id.uuidString)")
    }
}
