import RxCodeCore
import SwiftUI

struct HistoryListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @AppStorage("historyShowAllProjects") private var showAllProjects = true
    @AppStorage("historyShowArchived") private var showArchived = false
    @State private var showDeleteAllAlert = false
    @State private var sessionToDelete: ChatSession?
    @State private var sessionToArchive: ChatSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .alert(showArchived ? "Delete All Archived" : "Delete All", isPresented: $showDeleteAllAlert) {
            Button("Delete", role: .destructive) {
                let projectId: UUID?
                if windowState.isProjectWindow {
                    projectId = windowState.selectedProject?.id
                } else {
                    projectId = showAllProjects ? nil : windowState.selectedProject?.id
                }
                let archivedOnly = showArchived
                Task { await appState.deleteAllSessions(projectId: projectId, archivedOnly: archivedOnly, in: windowState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let isCurrentOnly = windowState.isProjectWindow || !showAllProjects
            switch (showArchived, isCurrentOnly) {
            case (true, true):
                Text("All archived chats in the current project will be deleted. This action cannot be undone.")
            case (true, false):
                Text("All archived chats will be deleted. This action cannot be undone.")
            case (false, true):
                Text("All sessions in the current project will be deleted. This action cannot be undone.")
            case (false, false):
                Text("All sessions will be deleted. This action cannot be undone.")
            }
        }
        .alert("Delete Session", isPresented: isDeletingSessionBinding) {
            Button("Delete", role: .destructive) {
                if let session = sessionToDelete {
                    Task { await appState.deleteSession(session, in: windowState) }
                }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
        } message: {
            if let session = sessionToDelete {
                Text("\"\(session.title)\" will be deleted. This action cannot be undone.")
            } else {
                Text("This session will be deleted. This action cannot be undone.")
            }
        }
        .alert("Archive Chat", isPresented: isArchivingSessionBinding) {
            Button("Archive", role: .destructive) {
                if let session = sessionToArchive {
                    Task { await appState.archiveSession(session, in: windowState) }
                }
                sessionToArchive = nil
            }
            Button("Cancel", role: .cancel) {
                sessionToArchive = nil
            }
        } message: {
            if let session = sessionToArchive {
                Text("\"\(session.title)\" will be archived. Archived chats are hidden from the active list and can be restored from Archived.")
            } else {
                Text("This chat will be archived. Archived chats are hidden from the active list and can be restored from Archived.")
            }
        }
        .alert("Rename Session", isPresented: isRenamingBinding) {
            TextField("Session name", text: $renameText)
            Button("Rename") {
                if let session = renamingSession, !renameText.isEmpty {
                    Task { await appState.renameSession(session, to: renameText) }
                }
                renamingSession = nil
            }
            Button("Cancel", role: .cancel) {
                renamingSession = nil
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text(showArchived ? "Archived" : "History")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)

            Spacer()

            // No need to toggle all/current in the project window
            if !windowState.isProjectWindow {
                Button {
                    showAllProjects.toggle()
                } label: {
                    Image(systemName: showAllProjects ? "tray.2" : "tray")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(showAllProjects ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
                .help(showAllProjects ? "Show current project only" : "Show all projects")
            }

            Button {
                showArchived.toggle()
            } label: {
                Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(showArchived ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
            }
            .buttonStyle(.borderless)
            .help(showArchived ? "Show active chats" : "Show archived chats")

            Button {
                showDeleteAllAlert = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.borderless)
            .help(showArchived ? "Delete All Archived" : "Delete All")
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        List(sessions, selection: selectedSessionBinding) { session in
            sessionRow(session)
                .tag(session.id)
        }
        .listStyle(.sidebar)
        .animation(.default, value: sessions)
    }

    private var selectedSessionBinding: Binding<String?> {
        Binding<String?>(
            get: { appState.currentSession(in: windowState)?.id },
            set: { id in
                if let id {
                    appState.selectSession(id: id, in: windowState)
                }
            }
        )
    }

    private func sessionRow(_ session: DisplaySession) -> some View {
        let projectName = (showAllProjects && !windowState.isProjectWindow) ? session.projectName : nil
        return SessionSidebarRow(
            title: session.title,
            projectName: projectName,
            updatedAt: session.updatedAt,
            isPinned: session.isPinned,
            isBackgroundStreaming: session.isBackgroundStreaming
        )
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 10, pressing: { pressing in
            if pressing {
                appState.selectSession(id: session.id, in: windowState)
            }
        }, perform: {})
        .contextMenu {
            if let summary = appState.allSessionSummaries.first(where: { $0.id == session.id }) {
                let chatSession = summary.makeSession()

                Button {
                    renameText = session.title
                    renamingSession = chatSession
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    Task { await appState.togglePinSession(chatSession) }
                } label: {
                    if session.isPinned {
                        Label("Unpin", systemImage: "pin.slash")
                    } else {
                        Label("Pin", systemImage: "pin")
                    }
                }

                Button {
                    if summary.isArchived {
                        Task {
                            await appState.unarchiveSession(chatSession, in: windowState)
                        }
                    } else {
                        sessionToArchive = chatSession
                    }
                } label: {
                    if summary.isArchived {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    } else {
                        Label("Archive", systemImage: "archivebox")
                    }
                }

                let hookItems = appState.threadContextMenuItems(for: summary)
                if !hookItems.isEmpty {
                    Divider()
                    HookContextMenuItems(items: hookItems)
                }

                Divider()

                Button(role: .destructive) {
                    sessionToDelete = chatSession
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: showArchived ? "archivebox" : "bubble.left.and.bubble.right")
                .font(.system(size: ClaudeTheme.size(20)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(showArchived ? "No archived chats" : "No chat history")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Display Model

    struct DisplaySession: Identifiable, Equatable {
        let id: String
        let projectId: UUID
        let title: String
        let updatedAt: Date
        let isPinned: Bool
        let isBackgroundStreaming: Bool
        let projectName: String?
    }

    private var sessions: [DisplaySession] {
        if windowState.isProjectWindow || !showAllProjects {
            return currentProjectSessions
        } else {
            return allProjectSessions
        }
    }

    static func sessionOrder(
        _ a: ChatSession.Summary, _ b: ChatSession.Summary
    ) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.updatedAt > b.updatedAt
    }

    /// Filter + sort the summary feed for the History sidebar.
    ///
    /// `projectId == nil` returns the all-projects feed (deduplicated by id).
    /// `projectId != nil` returns sessions scoped to that project. In either
    /// mode the result includes ONLY summaries whose `isArchived` matches
    /// `showArchived`, so archived chats never leak into the active list and
    /// active chats never leak into the Archived view.
    static func filteredSummaries(
        from summaries: [ChatSession.Summary],
        projectId: UUID?,
        showArchived: Bool
    ) -> [ChatSession.Summary] {
        if let projectId {
            return summaries
                .filter { $0.projectId == projectId && $0.isArchived == showArchived }
                .sorted { sessionOrder($0, $1) }
        }
        var seen = Set<String>()
        return summaries
            .filter { $0.isArchived == showArchived }
            .sorted { sessionOrder($0, $1) }
            .filter { seen.insert($0.id).inserted }
    }

    private var currentProjectSessions: [DisplaySession] {
        guard let projectId = windowState.selectedProject?.id else { return [] }
        let streamingIds = appState.backgroundStreamingSessionIds(in: windowState)
        return Self.filteredSummaries(
            from: appState.allSessionSummaries,
            projectId: projectId,
            showArchived: showArchived
        ).map { summary in
            DisplaySession(
                id: summary.id,
                projectId: summary.projectId,
                title: summary.title,
                updatedAt: summary.updatedAt,
                isPinned: summary.isPinned,
                isBackgroundStreaming: streamingIds.contains(summary.id),
                projectName: nil
            )
        }
    }

    private var allProjectSessions: [DisplaySession] {
        let projectNames = Dictionary(
            uniqueKeysWithValues: appState.projects.map { ($0.id, $0.name) }
        )
        let streamingIds = appState.backgroundStreamingSessionIds(in: windowState)
        return Self.filteredSummaries(
            from: appState.allSessionSummaries,
            projectId: nil,
            showArchived: showArchived
        ).map { summary in
            DisplaySession(
                id: summary.id,
                projectId: summary.projectId,
                title: summary.title,
                updatedAt: summary.updatedAt,
                isPinned: summary.isPinned,
                isBackgroundStreaming: streamingIds.contains(summary.id),
                projectName: projectNames[summary.projectId]
            )
        }
    }

    // MARK: - Helpers

    private var isDeletingSessionBinding: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    private var isArchivingSessionBinding: Binding<Bool> {
        Binding(
            get: { sessionToArchive != nil },
            set: { if !$0 { sessionToArchive = nil } }
        )
    }

    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )
    }

}

#Preview {
    HistoryListView()
        .environment(AppState())
        .environment(WindowState())
        .frame(width: 260)
}
