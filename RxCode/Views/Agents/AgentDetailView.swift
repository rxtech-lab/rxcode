import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// One agent's page: its header, then chat, activity, memory or schedules.
struct AgentDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(WindowState.self) private var window
    let agent: AgentProfile
    @Binding var sidebarVisible: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSelectAgent: (UUID) -> Void
    @State private var tab: AgentDetailTab = .chat

    var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            tabBar
            ClaudeThemeDivider()
            Group {
                switch tab {
                case .chat: chat
                case .activity: AgentActivityView(agent: agent, openThread: openThread)
                case .memory: AgentMemoryView(agent: agent)
                case .schedules: ScheduledTasksView(agentID: agent.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: agent.id) {
            do {
                try await state.ensureAgentWorkingDirectory(agent)
                // Keep a thread opened from elsewhere (notification, teammate request).
                if let projectId = window.selectedProject?.id, agent.owns(projectId: projectId) { return }
                state.openAgentConversation(agent.id, in: window)
            } catch {
                window.showError = true
                window.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let activity = state.agentActivity(agent.id)
        return AgentPageHeader(sidebarVisible: $sidebarVisible) {
            HStack(spacing: 10) {
                AgentAvatarView(agent: agent, activity: activity, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(agent.displayName)
                            .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        AgentActivityPill(activity: activity)
                    }
                    Text(modelLine)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            HStack(spacing: 4) {
                Menu {
                    Button("Edit Agent…", systemImage: "slider.horizontal.3", action: onEdit)
                    Divider()
                    Button("Delete Agent…", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Agent actions")
            }
            .buttonStyle(.borderless)
            .font(.system(size: ClaudeTheme.size(14)))
            .foregroundStyle(ClaudeTheme.textSecondary)
        }
    }

    private var modelLine: String {
        let config = state.resolvedAgentConfig(agent)
        let model = state.codingModelSections.flatMap(\.models)
            .first { $0.provider == config.provider && $0.id == config.model }?.displayName
            ?? config.model ?? String(localized: "Workspace default model")
        return "\(model) · \(agent.tone.displayNameText)"
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(AgentDetailTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.systemImage)
                        Text(item.title)
                        if let count = badge(for: item), count > 0 {
                            Text("\(count)")
                                .font(.system(size: ClaudeTheme.size(10), weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(ClaudeTheme.accent.opacity(0.18)))
                        }
                    }
                    .font(.system(size: ClaudeTheme.size(12), weight: tab == item ? .semibold : .regular))
                    .foregroundStyle(tab == item ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(tab == item ? ClaudeTheme.surfaceSecondary : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-\(item.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func badge(for tab: AgentDetailTab) -> Int? {
        switch tab {
        case .activity:
            state.agentJobs.filter { ($0.agentId == agent.id || $0.targetAgentId == agent.id) && $0.status.isActive }.count
        case .memory: state.agentMemory(agent.id).count
        case .schedules: state.agentSchedules(agent.id).count
        case .chat: nil
        }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            AgentThreadContextBanner(agent: agent, openConversation: {
                state.openAgentConversation(agent.id, in: window)
            })
            ChatView(inputAccessory: { ChatToolbarControls(placement: .composer) }, aboveInputAccessory: {
                VStack(spacing: 8) {
                    AgentConfirmationBanner()
                    PermissionQueueBanner()
                    ComputerUsePreviewBanner()
                }
            })
            .modifier(ChatDetailModifiers())
        }
    }

    private func openThread(_ sessionId: String) {
        state.openAgentThread(sessionId, in: window)
        tab = .chat
    }
}

enum AgentDetailTab: String, CaseIterable, Identifiable {
    case chat, activity, memory, schedules

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .chat: "Chat"
        case .activity: "Activity"
        case .memory: "Memory"
        case .schedules: "Schedules"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .activity: "waveform.path.ecg"
        case .memory: "brain"
        case .schedules: "calendar.badge.clock"
        }
    }
}

/// Explains which of the agent's threads is open when it isn't a plain
/// conversation: a teammate's request or a subagent run.
private struct AgentThreadContextBanner: View {
    @Environment(AppState.self) private var state
    @Environment(WindowState.self) private var window
    let agent: AgentProfile
    let openConversation: () -> Void

    var body: some View {
        if let text = contextText {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color(hex: agent.colorHex))
                Text(text)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button("Back to Conversation", action: openConversation)
                    .buttonStyle(.borderless)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(hex: agent.colorHex).opacity(0.08))
        }
    }

    private var summary: ChatSession.Summary? {
        guard let id = window.currentSessionId else { return nil }
        return state.allSessionSummaries.first { $0.id == id }
    }

    private var icon: String {
        guard let summary else { return "bubble.left.and.bubble.right" }
        if summary.projectId == agent.subagentProjectId { return "person.2.wave.2" }
        return summary.threadLabel == AgentJob.collaborationThreadLabel ? "bubble.left.and.bubble.right" : "clock.arrow.circlepath"
    }

    private var contextText: String? {
        guard let summary else { return nil }
        if summary.projectId == agent.subagentProjectId {
            return String(localized: "Subagent thread working for \(agent.displayName)")
        }
        guard summary.threadLabel == AgentJob.collaborationThreadLabel else {
            // The ongoing conversation needs no banner; an older thread does.
            guard summary.projectId == agent.id, state.agentConversationSummary(agent)?.id != summary.id else { return nil }
            return String(localized: "Earlier conversation from \(summary.updatedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        let job = state.agentJobs.first { $0.kind == .collaboration && $0.sessionKey == summary.id }
        let sender = job.flatMap { state.agentProfile(id: $0.agentId)?.displayName } ?? String(localized: "a teammate")
        return String(localized: "Answering a request from \(sender)")
    }
}

// MARK: - Activity

private struct AgentActivityView: View {
    @Environment(AppState.self) private var state
    let agent: AgentProfile
    let openThread: (String) -> Void
    @State private var inspecting: AgentJob?

    private var conversations: [ChatSession.Summary] { state.agentEarlierConversations(agent) }
    private var collaborations: [AgentJob] { state.agentCollaborations(involving: agent.id) }
    private var jobs: [AgentJob] { state.agentJobs(for: agent.id).filter { $0.kind != .collaboration } }

    var body: some View {
        Group {
            if conversations.isEmpty && collaborations.isEmpty && jobs.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Teammate requests and background jobs of \(agent.displayName) appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !collaborations.isEmpty {
                            section("Teammates", systemImage: "person.2.fill") {
                                ForEach(collaborations.prefix(30)) { job in
                                    AgentCollaborationRow(job: job, perspective: agent.id) { open(job) }
                                }
                            }
                        }
                        if !jobs.isEmpty {
                            section("Jobs", systemImage: "tray.full") {
                                ForEach(jobs.prefix(50)) { job in
                                    jobRow(job)
                                }
                            }
                        }
                        if !conversations.isEmpty {
                            section("Earlier Conversations", systemImage: "clock.arrow.circlepath") {
                                ForEach(conversations.prefix(30)) { summary in
                                    conversationRow(summary)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $inspecting) { job in
            AgentJobDetailSheet(jobId: job.id, openThread: openThread)
        }
    }

    private func open(_ job: AgentJob) {
        if let session = job.sessionKey { openThread(state.resolveCurrentSessionId(session)) } else { inspecting = job }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).fill(ClaudeTheme.surfacePrimary))
                .overlay(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).strokeBorder(ClaudeTheme.borderSubtle))
        }
    }

    private func jobRow(_ job: AgentJob) -> some View {
        Button { inspecting = job } label: {
            HStack(spacing: 10) {
                Image(systemName: job.kind.systemImage)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayTitle)
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(String(localized: job.kind.displayName)) · \(job.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                Spacer()
                AgentJobStatusBadge(status: job.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func conversationRow(_ summary: ChatSession.Summary) -> some View {
        Button { openThread(summary.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 22)
                Text(summary.title)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(summary.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One request between two agents: sender → teammate, with its status.
struct AgentCollaborationRow: View {
    @Environment(AppState.self) private var state
    let job: AgentJob
    /// The agent whose page shows the row, or `nil` on the team overview.
    var perspective: UUID?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: -6) {
                    avatar(job.agentId)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 22)
                    avatar(job.targetAgentId)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayTitle)
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(direction) · \(job.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                AgentJobStatusBadge(status: job.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if job.status.isActive {
                Button("Cancel Request", role: .destructive) { Task { await state.cancelAgentJob(job.id) } }
            }
        }
    }

    private var senderName: String { state.agentProfile(id: job.agentId)?.displayName ?? String(localized: "Deleted agent") }
    private var targetName: String {
        job.targetAgentId.flatMap { state.agentProfile(id: $0)?.displayName } ?? job.targetAgentName ?? String(localized: "Deleted agent")
    }

    private var direction: String {
        if perspective == job.agentId { return String(localized: "Asked \(targetName)") }
        if perspective == job.targetAgentId { return String(localized: "From \(senderName)") }
        return String(localized: "\(senderName) asked \(targetName)")
    }

    @ViewBuilder
    private func avatar(_ id: UUID?) -> some View {
        if let id, let agent = state.agentProfile(id: id) {
            AgentAvatarView(agent: agent, activity: .idle, size: 26, animated: false, showsStatus: false)
        } else {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 18))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - Job detail

private struct AgentJobDetailSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let jobId: UUID
    let openThread: (String) -> Void
    @State private var cancelling = false

    var body: some View {
        NavigationStack {
            Group {
                if let job = state.agentJob(id: jobId) {
                    Form {
                        Section {
                            LabeledContent("Type") { Label(job.kind.displayName, systemImage: job.kind.systemImage) }
                            LabeledContent("Status") { AgentJobStatusBadge(status: job.status) }
                            LabeledContent("Started", value: (job.startedAt ?? job.createdAt).formatted(date: .abbreviated, time: .shortened))
                            if let finished = job.finishedAt {
                                LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let code = job.exitCode { LabeledContent("Exit code", value: "\(code)") }
                        }
                        Section(job.kind == .shell ? "Command" : "Instructions") {
                            MarkdownContentView(text: job.prompt, style: .rxCodeCompact)
                        }
                        if let error = job.errorMessage, !error.isEmpty {
                            Section("Error") { MarkdownContentView(text: error, style: .rxCodeCompact) }
                        }
                        if let output = state.agentShellOutput(job.id) ?? job.resultSummary, !output.isEmpty {
                            Section(job.kind == .shell ? "Output" : "Result") { MarkdownContentView(text: output, style: .rxCodeCompact) }
                        }
                    }
                    .formStyle(.grouped)
                    .navigationTitle(job.displayTitle)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                        if let session = job.sessionKey {
                            ToolbarItem {
                                Button("Open Thread") {
                                    dismiss()
                                    openThread(state.resolveCurrentSessionId(session))
                                }
                            }
                        }
                        if job.status.isActive {
                            ToolbarItem {
                                Button("Cancel Job", role: .destructive) {
                                    cancelling = true
                                    Task {
                                        await state.cancelAgentJob(job.id)
                                        cancelling = false
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Job Not Found", systemImage: "tray")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .overlay { if cancelling { PetActionStatusOverlay(message: String(localized: "Cancelling job…")).allowsHitTesting(false) } }
    }
}

// MARK: - Memory

private struct AgentMemoryView: View {
    @Environment(AppState.self) private var state
    let agent: AgentProfile
    @State private var deleting: AgentMemoryNote?

    var body: some View {
        let notes = state.agentMemory(agent.id)
        Group {
            if notes.isEmpty {
                ContentUnavailableView(
                    "No Memory Yet",
                    systemImage: "brain",
                    description: Text("\(agent.displayName) saves preferences, facts and decisions here as you talk.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(notes) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Label(note.kind.displayName, systemImage: note.kind.systemImage)
                                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                        .foregroundStyle(Color(hex: agent.colorHex))
                                    Spacer()
                                    Text(note.updatedAt.formatted(.relative(presentation: .named)))
                                        .font(.system(size: ClaudeTheme.size(11)))
                                        .foregroundStyle(ClaudeTheme.textTertiary)
                                }
                                MarkdownContentView(text: note.content, style: .rxCodeCompact)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).fill(ClaudeTheme.surfacePrimary))
                            .overlay(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).strokeBorder(ClaudeTheme.borderSubtle))
                            .contextMenu {
                                Button("Delete Note…", role: .destructive) { deleting = note }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .confirmationDialog(
            "Delete this memory note?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { note in
            Button("Delete Note", role: .destructive) { state.deleteAgentMemory(id: note.id) }
        } message: { _ in
            Text("\(agent.displayName) will no longer remember it.")
        }
    }
}
