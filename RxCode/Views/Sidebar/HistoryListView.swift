import SwiftUI
import RxCodeCore

struct HistoryListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @AppStorage("historyShowAllProjects") private var showAllProjects = true
    @AppStorage("historyShowArchived") private var showArchived = false
    @State private var showDeleteAllAlert = false
    @State private var sessionToDelete: ChatSession?

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
        return HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                TypewriterTitleText(title: session.title.prefix(1).uppercased() + session.title.dropFirst())
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: session.title)

                HStack(spacing: 4) {
                    if showAllProjects && !windowState.isProjectWindow, let projectName = session.projectName {
                        Text(projectName)
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accent.opacity(0.8))
                            .lineLimit(1)

                        Text("·")
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(.tertiary)
                    }

                    Text(formattedDate(session.updatedAt))
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if session.isBackgroundStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .help("Response in progress in the background")
            }

            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(.vertical, 2)
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
                    Task {
                        if summary.isArchived {
                            await appState.unarchiveSession(chatSession, in: windowState)
                        } else {
                            await appState.archiveSession(chatSession, in: windowState)
                        }
                    }
                } label: {
                    if summary.isArchived {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    } else {
                        Label("Archive", systemImage: "archivebox")
                    }
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

    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )
    }

    private func formattedDate(_ date: Date) -> String {
        Self.compactElapsedTime(since: date)
    }

    private static func compactElapsedTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "0m" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }

        return "\(days / 365)y"
    }
}

#Preview {
    HistoryListView()
        .environment(AppState())
        .environment(WindowState())
        .frame(width: 260)
}
