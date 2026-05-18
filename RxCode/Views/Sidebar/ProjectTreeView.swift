import SwiftUI
import RxCodeCore

// MARK: - ProjectTreeView

/// Left sidebar root. Replaces the History/Files toggle.
/// Lists projects as collapsible disclosure rows; each project expands to show
/// its chats with a status dot.
struct ProjectTreeView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow

    @State private var expandedProjectIds: Set<UUID> = []
    @State private var renameProject: Project? = nil
    @State private var renameProjectText: String = ""
    @State private var deleteProject: Project? = nil

    @State private var renameSession: ChatSession? = nil
    @State private var renameSessionText: String = ""
    @State private var deleteSession: ChatSession? = nil

    @State private var showAllChatsSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummarySidebarSection()
                .padding(.top, 8)

            ClaudeThemeDivider()
                .padding(.vertical, 4)

            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if appState.projects.isEmpty {
                emptyState
            } else {
                projectList
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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Projects")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)

            Spacer()

            Button {
                showAllChatsSheet = true
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.borderless)
            .help("Show all chats")
    }
}

// MARK: - SummarySidebarSection

private struct SummarySidebarSection: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("General")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            Button {
                windowState.showingBriefing = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.page")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .frame(width: 18, height: 18)

                    Text("Briefing")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 4)
                }
                .foregroundStyle(windowState.showingBriefing ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                        .fill(windowState.showingBriefing ? ClaudeTheme.accent.opacity(0.10) : Color.clear)
                )
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open project branch briefing")
        }
    }
}

// MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 24)
            Image(systemName: "folder.badge.plus")
                .font(.system(size: ClaudeTheme.size(22)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No projects yet")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text("Click + in the toolbar to add one.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project List

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(appState.projects) { project in
                    ProjectTreeRow(
                        project: project,
                        isExpanded: Binding(
                            get: { expandedProjectIds.contains(project.id) },
                            set: { newValue in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if newValue { expandedProjectIds.insert(project.id) }
                                    else { expandedProjectIds.remove(project.id) }
                                }
                            }
                        ),
                        isSelected: windowState.selectedProject?.id == project.id,
                        onSelectProject: { appState.selectProject(project, in: windowState) },
                        onOpenInNewWindow: {
                            openWindow(id: "project-window",
                                       value: ProjectWindowValue(projectId: project.id, instanceId: UUID()))
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
    }
}

// MARK: - ProjectTreeRow

private struct ProjectTreeRow: View {
    let project: Project
    @Binding var isExpanded: Bool
    let isSelected: Bool
    let onSelectProject: () -> Void
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
                Image(systemName: "folder.fill")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse chats" : "Expand chats")

            Text(project.name)
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
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

            Spacer(minLength: 4)

            // Always reserve space; fade in on hover so layout doesn't shift.
            HStack(spacing: 2) {
                Menu {
                    Button { onNewChat() } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    Button { onOpenInNewWindow() } label: {
                        Label("Open in New Window", systemImage: "macwindow.badge.plus")
                    }
                    Divider()
                    Button { onRename() } label: {
                        Label("Rename Project", systemImage: "pencil")
                    }
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
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
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(isHovered ? ClaudeTheme.surfaceSecondary.opacity(0.45) : Color.clear)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onSelectProject()
            if !isExpanded { isExpanded = true }
        }
        .onTapGesture(count: 2) {
            onOpenInNewWindow()
        }
        .contextMenu {
            Button {
                onNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            Button {
                onOpenInNewWindow()
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Divider()
            Button {
                onRename()
            } label: {
                Label("Rename Project", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
    }
}

// MARK: - ProjectChatsList

private struct ProjectChatsList: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private static let defaultVisibleThreadCount = 5

    let project: Project
    let onSelectSession: (String) -> Void
    let onRenameSession: (ChatSession) -> Void
    let onDeleteSession: (ChatSession) -> Void

    @State private var showsAllThreads = false

    private var sessions: [ChatSession.Summary] {
        HistoryListView.filteredSummaries(
            from: appState.allSessionSummaries,
            projectId: project.id,
            showArchived: false
        )
    }

    private var collapsedVisibleCount: Int {
        let pinnedCount = sessions.prefix(while: { $0.isPinned }).count
        // Cap pinned slots at 6, then guarantee at least 4 unpinned rows so
        // recent unpinned threads remain visible even when pinned threads
        // would otherwise fill the collapsed list.
        let pinnedShown = min(pinnedCount, 6)
        let unpinnedShown = max(4, 6 - pinnedShown)
        let dynamic = pinnedShown + unpinnedShown
        return max(Self.defaultVisibleThreadCount, dynamic)
    }

    private var visibleSessions: [ChatSession.Summary] {
        guard !showsAllThreads else { return sessions }
        return Array(sessions.prefix(collapsedVisibleCount))
    }

    private var hiddenThreadCount: Int {
        max(0, sessions.count - collapsedVisibleCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessions.isEmpty {
                Text("No chats yet")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.leading, 28)
                    .padding(.vertical, 4)
            } else {
                ForEach(visibleSessions) { summary in
                    chatRow(for: summary)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }

                if hiddenThreadCount > 0 {
                    threadLimitToggle
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: showsAllThreads)
    }

    private var threadLimitToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                showsAllThreads.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsAllThreads ? "chevron.up" : "chevron.down")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                    .frame(width: 12, height: 12)

                Text(showsAllThreads ? "Hide more" : "Show more")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))

                if !showsAllThreads {
                    Text("\(hiddenThreadCount)")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
            .padding(.leading, 28)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsAllThreads ? "Show only the first five threads" : "Show all threads in this project")
    }

    private func chatRow(for summary: ChatSession.Summary) -> some View {
        let sessionId = summary.id
        let session = summary.makeSession()
        let status = appState.chatStatus(forSessionId: sessionId, in: windowState)
        let progress = appState.todoProgress(forSessionId: sessionId)

        return ProjectChatRow(
            summary: summary,
            isCurrent: !windowState.showingBriefing && windowState.currentSessionId == sessionId,
            status: status,
            todoProgress: progress,
            onSelect: { onSelectSession(sessionId) },
            onRename: { onRenameSession(session) },
            onTogglePin: {
                Task { await appState.togglePinSession(session) }
            },
            onToggleArchive: {
                Task {
                    if summary.isArchived {
                        await appState.unarchiveSession(session, in: windowState)
                    } else {
                        await appState.archiveSession(session, in: windowState)
                    }
                }
            },
            onDelete: {
                onDeleteSession(session)
            }
        )
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
