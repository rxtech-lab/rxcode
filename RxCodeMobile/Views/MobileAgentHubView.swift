import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// The Agent tab: Flowcy's cloud assistant or one of the paired Mac's agents,
/// picked from the dropdown in the navigation bar.
struct MobileAssistantView: View {
    static let selectionKey = "flowcy.assistant.selection"

    @EnvironmentObject private var state: MobileAppState
    /// The selected agent's id, or empty for Flowcy.
    @AppStorage(Self.selectionKey) private var selection = ""
    var onPair: () -> Void
    var onShowTools: () -> Void
    @State private var editing: MobileAgentEditorDraft?
    @State private var deleting: AgentHubAgent?
    @State private var status: String?
    @State private var error: String?

    private var selectedAgent: AgentHubAgent? {
        guard state.isPaired, let id = UUID(uuidString: selection) else { return nil }
        return state.agentHub.agent(id: id)
    }

    var body: some View {
        Group {
            if let agent = selectedAgent {
                MobileAgentConversationView(
                    agent: agent,
                    onEdit: { editing = MobileAgentEditorDraft(profile: agent.profile, isNew: false) },
                    onDelete: { deleting = agent }
                )
                .id(agent.id)
            } else {
                FlowcyAgentView()
                    .toolbar { FlowcyRemoteToolbar() }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Flowcy Tools", systemImage: "wrench.and.screwdriver") {
                                MobileHaptics.buttonTap()
                                onShowTools()
                            }
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                MobileAssistantPicker(selection: $selection, selectedAgent: selectedAgent, onNewAgent: newAgent, onPair: onPair)
            }
        }
        .onChange(of: selection) { _, _ in MobileHaptics.buttonTap() }
        .task(id: state.pairedDesktopPubkey) {
            if state.isPaired { try? await state.sendAgentPayload(.agentRequest(.init(operation: .refresh))) }
        }
        .sheet(item: $editing) { draft in
            MobileAgentEditorSheet(draft: draft) { saved in
                if draft.isNew { selection = saved.uuidString }
            }
            .environmentObject(state)
            .mobileSheetPresentation([.large])
        }
        .confirmationDialog(
            "Delete agent and its schedules, memory, and jobs?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { agent in
            Button("Delete \(agent.profile.displayName)", role: .destructive) { delete(agent) }
        } message: { _ in
            Text("Its conversations stay in history and search on your Mac.")
        }
        .alert("Could Not Delete Agent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .overlay {
            if let status {
                ProgressView(status)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func newAgent() {
        let count = state.agentHub.agents.count
        let profile = AgentProfile(name: "", colorHex: AgentProfile.palette[count % AgentProfile.palette.count])
        editing = MobileAgentEditorDraft(profile: profile, isNew: true)
    }

    private func delete(_ agent: AgentHubAgent) {
        deleting = nil
        status = String(localized: "Deleting \(agent.profile.displayName)…")
        Task {
            do {
                _ = try await state.performAgentRequest(.init(operation: .deleteAgent, agentID: agent.id))
                if selection == agent.id.uuidString { selection = "" }
                MobileHaptics.connected()
            } catch {
                self.error = error.localizedDescription
                MobileHaptics.connectionError()
            }
            status = nil
        }
    }
}

/// The navigation-bar dropdown that switches between Flowcy and the Mac's agents.
private struct MobileAssistantPicker: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selection: String
    let selectedAgent: AgentHubAgent?
    let onNewAgent: () -> Void
    let onPair: () -> Void

    var body: some View {
        Menu {
            Picker("Assistant", selection: Binding(get: { selectedAgent?.id.uuidString ?? "" }, set: { selection = $0 })) {
                Label("Flowcy", systemImage: "sparkles").tag("")
                if state.isPaired, !state.agentHub.agents.isEmpty {
                    Section(state.pairedDesktopName.isEmpty ? String(localized: "Agents") : state.pairedDesktopName) {
                        ForEach(state.agentHub.agents) { agent in
                            Label(agent.profile.displayName, systemImage: agent.profile.symbol)
                                .tag(agent.id.uuidString)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            if state.isPaired {
                Button("New Agent…", systemImage: "plus") {
                    MobileHaptics.buttonTap()
                    onNewAgent()
                }
            } else {
                Button("Connect a Mac to Use Agents", systemImage: "laptopcomputer") {
                    MobileHaptics.buttonTap()
                    onPair()
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let agent = selectedAgent {
                    MobileAgentAvatar(profile: agent.profile, size: 22, isStreaming: agent.isStreaming)
                    Text(agent.profile.displayName)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    Text("Flowcy")
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Choose assistant")
        .accessibilityValue(selectedAgent?.profile.displayName ?? "Flowcy")
        .accessibilityIdentifier("assistant-picker")
    }
}

/// The agent's symbol in a tinted circle.
struct MobileAgentAvatar: View {
    let profile: AgentProfile
    var size: CGFloat = 28
    var isStreaming = false

    var body: some View {
        Image(systemName: profile.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Color(hex: profile.colorHex))
            .frame(width: size, height: size)
            .background(Color(hex: profile.colorHex).opacity(0.16), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if isStreaming {
                    Circle().fill(.green).frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Conversation

private enum MobileAgentPage: Hashable, Identifiable {
    case activity, memory, schedules, messages
    var id: Self { self }
}

/// One agent's ongoing conversation. Like the Mac's Agents tab it never ends:
/// every message continues the same thread, which the Mac shares too.
private struct MobileAgentConversationView: View {
    @EnvironmentObject private var state: MobileAppState
    let agent: AgentHubAgent
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// The thread the first message started, until the Mac's hub update links it.
    @State private var startedSessionID: String?
    @State private var page: MobileAgentPage?
    @State private var showingScreen = false

    private var sessionID: String? { agent.primarySessionId ?? startedSessionID }

    var body: some View {
        Group {
            if let sessionID {
                MobileChatView(sessionID: sessionID, showsThreadToolbar: false)
                    .id(sessionID)
            } else {
                MobileAgentFirstMessageView(agent: agent) { startedSessionID = $0 }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit Agent…", systemImage: "slider.horizontal.3") {
                        MobileHaptics.buttonTap()
                        onEdit()
                    }
                    Button("View Mac Screen", systemImage: "display") {
                        MobileHaptics.buttonTap()
                        showingScreen = true
                    }
                    .disabled(!state.agentHub.remoteAccess.allowsViewing)
                    Divider()
                    pageButton(.activity, title: "Activity", systemImage: "waveform.path.ecg")
                    pageButton(.memory, title: "Memory", systemImage: "brain")
                    pageButton(.schedules, title: "Schedules", systemImage: "calendar.badge.clock")
                    if !agent.profile.phoneMessages.isEmpty {
                        pageButton(.messages, title: "Messages from Agent", systemImage: "bell.badge")
                    }
                    Divider()
                    Button("Delete Agent…", systemImage: "trash", role: .destructive) {
                        MobileHaptics.buttonTap()
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Agent actions")
                .accessibilityIdentifier("agent-actions-menu")
            }
        }
        .navigationDestination(item: $page) { page in
            switch page {
            case .activity: MobileAgentJobsView(agentID: agent.id)
            case .memory: MobileAgentMemoryView(agentID: agent.id)
            case .schedules: MobileAgentSchedulesView(agentID: agent.id)
            case .messages: MobileAgentMessagesView(agentID: agent.id)
            }
        }
        .sheet(isPresented: $showingScreen) { MobileAgentScreenView().environmentObject(state) }
        .onChange(of: agent.primarySessionId) { _, id in
            if id != nil { startedSessionID = nil }
        }
    }

    private func pageButton(_ target: MobileAgentPage, title: LocalizedStringKey, systemImage: String) -> some View {
        Button(title, systemImage: systemImage) {
            MobileHaptics.buttonTap()
            page = target
        }
    }
}

/// Shown until the agent's conversation exists; the first message starts it.
private struct MobileAgentFirstMessageView: View {
    @EnvironmentObject private var state: MobileAppState
    let agent: AgentHubAgent
    let onStarted: (String) -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 14) {
            MobileAgentAvatar(profile: agent.profile, size: 72)
            Text(agent.profile.displayName).font(.title2.bold())
            Text(agent.profile.roleSummary.isEmpty
                 ? String(localized: "Say hello to start the conversation. It carries on between your Mac and this phone.")
                 : agent.profile.roleSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !agent.modelLabel.isEmpty {
                Label(agent.modelLabel, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .safeAreaBar(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(agent.profile.displayName)…", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 7)
                    .focused($focused)
                    .accessibilityIdentifier("agent-first-message-composer")
                if !trimmed.isEmpty {
                    MobileComposerButton("Send", systemImage: "arrow.up", style: .accent) { send() }
                        .disabled(sending)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: trimmed.isEmpty)
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 48)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .frame(maxWidth: 820)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .overlay {
            if sending {
                ProgressView("Sending…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Message Delivery", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func send() {
        let message = trimmed
        guard !message.isEmpty, !sending else { return }
        MobileHaptics.buttonTap()
        sending = true
        focused = false
        Task {
            do {
                let result = try await state.performAgentRequest(
                    .init(operation: .sendMessage, agentID: agent.id, text: message)
                )
                text = ""
                if let session = result.sessionID { onStarted(session) }
            } catch {
                self.error = error.localizedDescription
                MobileHaptics.connectionError()
            }
            sending = false
        }
    }
}

// MARK: - Agent pages

private struct MobileAgentJobsView: View {
    @EnvironmentObject private var state: MobileAppState
    let agentID: UUID

    var body: some View {
        let jobs = state.agentHub.jobs(for: agentID)
        List(jobs) { job in
            NavigationLink {
                if let key = job.sessionKey {
                    MobileChatView(sessionID: key)
                } else {
                    ScrollView {
                        MarkdownContentView(text: job.errorMessage ?? job.resultSummary ?? job.prompt).padding()
                    }
                    .navigationTitle(job.title)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(job.title, systemImage: job.kind.systemImage)
                    Text(job.status.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Activity")
    }
}

private struct MobileAgentMemoryView: View {
    @EnvironmentObject private var state: MobileAppState
    let agentID: UUID

    var body: some View {
        let notes = state.agentHub.memory(for: agentID)
        List(notes) { MarkdownContentView(text: $0.content, style: .rxCodeCompact) }
            .overlay {
                if notes.isEmpty {
                    ContentUnavailableView("No Memory Yet", systemImage: "brain")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Memory")
    }
}

private struct MobileAgentSchedulesView: View {
    @EnvironmentObject private var state: MobileAppState
    let agentID: UUID

    var body: some View {
        let tasks = state.agentHub.schedules(for: agentID)
        List(tasks) { task in
            LabeledContent(task.name, value: task.dueAt?.formatted() ?? task.cronExpression)
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView("No Schedules", systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Schedules")
    }
}

private struct MobileAgentMessagesView: View {
    @EnvironmentObject private var state: MobileAppState
    let agentID: UUID

    var body: some View {
        let notices = state.agentHub.agent(id: agentID)?.profile.phoneMessages ?? []
        List(notices) { notice in
            VStack(alignment: .leading, spacing: 4) {
                MarkdownContentView(text: notice.body, style: .rxCodeCompact)
                Text(notice.sentAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                if let session = notice.sessionID {
                    NavigationLink("Open Conversation") { MobileChatView(sessionID: session) }
                }
            }
        }
        .overlay {
            if notices.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "bell")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Messages from Agent")
    }
}

// MARK: - Requests

enum MobileAgentRequestError: LocalizedError {
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "The Mac has not confirmed the change. Check RxCode on your Mac before retrying.")
        case .failed(let message): message.isEmpty ? String(localized: "The Mac could not complete the request.") : message
        }
    }
}

extension MobileAppState {
    func sendAgentPayload(_ payload: RxCodeSync.Payload) async throws {
        guard isPaired else { throw URLError(.notConnectedToInternet) }
        try await client.send(payload, toHex: pairedDesktopPubkey)
    }

    /// Sends `request` and waits for the Mac's matching result.
    func performAgentRequest(_ request: AgentRequestPayload, timeout: Duration = .seconds(30)) async throws -> AgentResultPayload {
        let id = request.clientRequestID
        let result = try await withThrowingTaskGroup(of: AgentResultPayload?.self) { group in
            group.addTask { @MainActor in
                // `@Published` replays its current value, so a result that lands
                // before this loop subscribes is still seen.
                for await result in self.$latestAgentResult.values where result?.clientRequestID == id {
                    return result
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MobileAgentRequestError.timedOut
            }
            defer { group.cancelAll() }
            try await sendAgentPayload(.agentRequest(request))
            guard let first = try await group.next(), let result = first else { throw MobileAgentRequestError.timedOut }
            return result
        }
        guard result.ok else { throw MobileAgentRequestError.failed(result.error ?? "") }
        return result
    }
}
