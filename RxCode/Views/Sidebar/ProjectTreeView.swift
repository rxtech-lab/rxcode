import RxCodeCore
import SwiftUI

enum SidebarTreeSelection: Equatable {
    case project(UUID)
    case thread(String)
}

extension WindowState {
    var sidebarTreeSelection: SidebarTreeSelection? {
        switch generalRoute {
        case .tasks:
            return taskDetailProjectId.map(SidebarTreeSelection.project)
        case nil:
            if let currentSessionId { return .thread(currentSessionId) }
            return selectedProject.map { .project($0.id) }
        default:
            return nil
        }
    }
}

// MARK: - ProjectTreeView

/// Workspace navigation, live agent runs, and project history share one sidebar.
struct ProjectTreeView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow

    @State private var expandedProjectIds: Set<UUID> = []
    @State private var historyPerformance = ChatHistoryPerformanceLog()
    @State private var renameProject: Project? = nil
    @State private var renameProjectText: String = ""
    @State private var deleteProject: Project? = nil

    @State private var renameSession: ChatSession? = nil
    @State private var renameSessionText: String = ""
    @State private var deleteSession: ChatSession? = nil
    @State private var archiveSession: ChatSession? = nil

    @State private var showAllChatsSheet = false

    /// Identity for the dirty-flag refresh task — changes whenever a project is
    /// added/removed or its path changes, re-running `refreshProjectGitDirty`.
    private var gitDirtyRefreshKey: String {
        appState.projects.map { "\($0.id.uuidString):\($0.path)" }.joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarNavigationSection()

            ClaudeThemeDivider()

            if appState.projects.isEmpty {
                SidebarActivitySection()
                emptyState
            } else {
                projectList
            }

            if let project = windowState.selectedProject, !project.isGlobalChat {
                ClaudeThemeDivider()
                SidebarRepositoryView(project: project)
            }
        }
        // Keep the per-project dirty flag fresh so "Commit All Changes" hides on
        // clean projects. Recompute when the project set changes and whenever a
        // turn finishes (a commit/agent run may have cleaned the tree).
        .task(id: gitDirtyRefreshKey) {
            await appState.refreshProjectGitDirty()
        }
        // `isStreamingActivity`, not `isStreaming(in:)`: the latter reads
        // `sessionStates`, which re-rendered this whole tree (and every row's
        // eagerly built context menus) on every stream event.
        .onChange(of: appState.isStreamingActivity(in: windowState)) { old, new in
            if old && !new {
                Task { await appState.refreshProjectGitDirty() }
            }
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renameProject != nil },
            set: { if !$0 { renameProject = nil } }
        )) {
            TextField("Project name", text: $renameProjectText)
            Button("Rename") {
                if let p = renameProject, !renameProjectText.isEmpty {
                    Task { await appState.renameProject(p, to: renameProjectText) }
                }
                renameProject = nil
            }
            Button("Cancel", role: .cancel) { renameProject = nil }
        }
        .confirmationDialog(
            "Delete \"\(deleteProject?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteProject != nil },
                set: { if !$0 { deleteProject = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = deleteProject {
                    Task { await appState.deleteProject(p, in: windowState) }
                }
                deleteProject = nil
            }
            Button("Cancel", role: .cancel) { deleteProject = nil }
        } message: {
            Text("This will remove the project from RxCode. The files on disk will not be deleted.")
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renameSession != nil },
            set: { if !$0 { renameSession = nil } }
        )) {
            TextField("Session name", text: $renameSessionText)
            Button("Rename") {
                if let s = renameSession, !renameSessionText.isEmpty {
                    Task { await appState.renameSession(s, to: renameSessionText) }
                }
                renameSession = nil
            }
            Button("Cancel", role: .cancel) { renameSession = nil }
        }
        .alert("Delete Session", isPresented: Binding(
            get: { deleteSession != nil },
            set: { if !$0 { deleteSession = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let s = deleteSession {
                    Task { await appState.deleteSession(s, in: windowState) }
                }
                deleteSession = nil
            }
            Button("Cancel", role: .cancel) { deleteSession = nil }
        } message: {
            if let s = deleteSession {
                Text("\"\(s.title)\" will be deleted. This action cannot be undone.")
            } else {
                Text("This session will be deleted. This action cannot be undone.")
            }
        }
        .alert("Archive Chat", isPresented: Binding(
            get: { archiveSession != nil },
            set: { if !$0 { archiveSession = nil } }
        )) {
            Button("Archive", role: .destructive) {
                if let s = archiveSession {
                    Task { await appState.archiveSession(s, in: windowState) }
                }
                archiveSession = nil
            }
            Button("Cancel", role: .cancel) { archiveSession = nil }
        } message: {
            if let s = archiveSession {
                Text("\"\(s.title)\" will be archived. Archived chats are hidden from the active list and can be restored from Archived.")
            } else {
                Text("This chat will be archived. Archived chats are hidden from the active list and can be restored from Archived.")
            }
        }
        .sheet(isPresented: $showAllChatsSheet) {
            AllChatsHistorySheet(isPresented: $showAllChatsSheet)
        }
        .onChange(of: windowState.selectedProject?.id) { _, newId in
            if let newId { expandedProjectIds.insert(newId) }
        }
        .onAppear {
            if let id = windowState.selectedProject?.id {
                expandedProjectIds.insert(id)
            }
        }
        .task(id: appState.projects.map { $0.gitHubRepo ?? "" }.joined(separator: ",")) {
            await appState.refreshSecretsStatuses()
            await appState.refreshDocsStatuses()
            await appState.refreshReleaseStatuses()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Projects")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Spacer()

            Button {
                showAllChatsSheet = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all chats")
            .help("Show all chats")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView("No projects yet", systemImage: "folder.badge.plus",
                               description: Text("Use + in the toolbar to add a project."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Project List

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SidebarActivitySection()

                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(appState.projects) { project in
                    ProjectTreeRow(
                        project: project,
                        isExpanded: Binding(
                            get: { expandedProjectIds.contains(project.id) },
                            set: { newValue in
                                historyPerformance.log("project disclosure project=\(project.id) expanded=\(newValue) summaries=\(appState.allSessionSummaries.count)")
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if newValue { expandedProjectIds.insert(project.id) }
                                    else { expandedProjectIds.remove(project.id) }
                                }
                            }
                        ),
                        isSelected: windowState.sidebarTreeSelection == .project(project.id),
                        onOpenInNewWindow: {
                            openWindow(id: "project-window",
                                       value: ProjectWindowValue(projectId: project.id, instanceId: UUID(), workspaceID: appState.activeWorkspace.id))
                        },
                        onRename: {
                            renameProjectText = project.name
                            renameProject = project
                        },
                        onDelete: { deleteProject = project },
                        onNewChat: {
                            appState.selectProject(project, in: windowState)
                            appState.startNewChat(in: windowState)
                        }
                    )

                    if expandedProjectIds.contains(project.id) {
                        ProjectChatsList(
                            project: project,
                            onSelectSession: { id in
                                appState.selectSession(id: id, in: windowState)
                            },
                            onRenameSession: { session in
                                renameSessionText = session.title
                                renameSession = session
                            },
                            onArchiveSession: { session in
                                archiveSession = session
                            },
                            onDeleteSession: { session in
                                deleteSession = session
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                    }
                }
            }
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.18), value: expandedProjectIds)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            historyPerformance.log("project sidebar scroll \(oldPhase) -> \(newPhase) expandedProjects=\(expandedProjectIds.count)")
        }
    }
}

// MARK: - ProjectTreeRow

private struct ProjectTreeRow: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let project: Project
    @Binding var isExpanded: Bool
    let isSelected: Bool
    let onOpenInNewWindow: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onNewChat: () -> Void
    @State private var isHovered = false
    @State private var showLocationPopover = false
    @State private var hoverTask: Task<Void, Never>?

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if project.path.hasPrefix(home) {
            return "~" + project.path.dropFirst(home.count)
        }
        return project.path
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                }
                    .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse chats in \(project.name)" : "Expand chats in \(project.name)")
            .help(isExpanded ? "Collapse chats" : "Expand chats")

            Text(project.name)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .onHover { hovering in
                    hoverTask?.cancel()
                    if hovering {
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run { showLocationPopover = true }
                        }
                    } else {
                        showLocationPopover = false
                    }
                }
                .popover(isPresented: $showLocationPopover, arrowEdge: .trailing) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(ClaudeTheme.statusWarning)
                        Text(displayPath)
                            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }

            ProjectTreeAttentionBadge(projectId: project.id)

            if let status = appState.ciStatusByProject[project.id],
               status.pullRequestState == .open,
               project.gitHubRepo?.caseInsensitiveCompare("\(status.owner)/\(status.repo)") == .orderedSame {
                let title = status.prNumber.map { String(localized: "Pull request #\($0)") }
                    ?? String(localized: "Pull request")
                let label = String(localized: "\(title) · Open")
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                    .help(label)
                    .accessibilityLabel(label)
            }

            Spacer(minLength: 4)

            // Always reserve space; fade in on hover so layout doesn't shift.
            HStack(spacing: 2) {
                Menu {
                    projectMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")

                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Chat in \(project.name)")
            }
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(isSelected ? ClaudeTheme.accentSubtle : (isHovered ? ClaudeTheme.surfaceSecondary : .clear))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            windowState.generalRoute = .tasks
            windowState.taskDetailProjectId = project.id
            appState.focusProject(id: project.id, in: windowState)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            projectMenuItems
        }
    }

    /// Shared items for both the "More" (ellipsis) menu and the right-click
    /// context menu so the two stay in sync.
    @ViewBuilder
    private var projectMenuItems: some View {
        Button { onNewChat() } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
        Button { onOpenInNewWindow() } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        ProjectTreeHookMenuItems(project: project)
        Divider()
        ProjectCloudMenuItems(project: project)
        Divider()
        Button { onRename() } label: {
            Label("Rename Project", systemImage: "pencil")
        }
        Button(role: .destructive) { onDelete() } label: {
            Label("Delete Project", systemImage: "trash")
        }
    }

}

private struct ProjectTreeAttentionBadge: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    let projectId: UUID

    var body: some View {
        AttentionBadge(attention: appState.projectAttention(projectId: projectId, in: windowState))
    }
}

/// Keep hook dependencies out of the row's hover and disclosure updates.
private struct ProjectTreeHookMenuItems: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    let project: Project

    var body: some View {
        let items = appState.projectContextMenuItems(for: project)
        if !items.isEmpty {
            Divider()
            MenuItemsView(items)
                .menuActionHandler(appState.desktopMenuActionHandler(navigatingIn: windowState))
        }
    }
}

// MARK: - All-Chats sheet

private struct AllChatsHistorySheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All Chats")
                    .font(.headline)
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ClaudeThemeDivider()

            HistoryListView()
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 500, idealHeight: 700)
        .background(ClaudeTheme.background)
    }
}
