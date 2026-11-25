import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// The Agents tab: a sidebar to pick an agent (or the team overview and
/// workspace schedules) beside the selected page.
struct AgentHubView: View {
    @Environment(AppState.self) private var state
    @Environment(WindowState.self) private var window
    @SceneStorage("agentHubSidebarVisible") private var showsSidebar = true
    @State private var page: AgentHubPage = .team
    @State private var draft: AgentProfile?
    @State private var deleting: AgentProfile?
    @State private var showsRemoteAccess = false
    @State private var status: String?

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                AgentHubSidebar(
                    page: $page,
                    onNew: newAgent,
                    onEdit: { draft = $0 },
                    onDelete: { deleting = $0 },
                    onRemoteAccess: { showsRemoteAccess = true }
                )
                .frame(width: 272)
                .transition(.move(edge: .leading))
                Rectangle().fill(ClaudeTheme.divider).frame(width: 1)
            }
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ClaudeTheme.background)
        }
        .clipped()
        .onAppear(perform: syncPageWithWindow)
        .onChange(of: window.selectedProject?.id) { _, _ in syncPageWithWindow() }
        .onChange(of: state.agentProfiles.map(\.id)) { _, ids in
            if case .agent(let id) = page, !ids.contains(id) { page = .team }
        }
        .sheet(item: $draft) { profile in AgentProfileEditor(profile: profile) }
        .sheet(isPresented: $showsRemoteAccess) { AgentRemoteAccessView() }
        .confirmationDialog(
            "Delete agent and its schedules, memory, and jobs?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { agent in
            Button("Delete \(agent.displayName)", role: .destructive) { delete(agent) }
        } message: { _ in
            Text("Its conversations stay in history and search.")
        }
        .overlay { if let status { PetActionStatusOverlay(message: status).allowsHitTesting(false) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-hub-view")
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .team:
            AgentTeamOverview(
                sidebarVisible: $showsSidebar,
                onSelect: { page = .agent($0) },
                onNew: newAgent
            )
        case .agent(let id):
            if let agent = state.agentProfile(id: id) {
                AgentDetailView(
                    agent: agent,
                    sidebarVisible: $showsSidebar,
                    onEdit: { draft = agent },
                    onDelete: { deleting = agent },
                    onSelectAgent: { page = .agent($0) }
                )
                .id(id)
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "person.crop.circle.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .schedules:
            VStack(spacing: 0) {
                AgentPageHeader(sidebarVisible: $showsSidebar) {
                    Label("Workspace Schedules", systemImage: "calendar.badge.clock")
                        .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                }
                ClaudeThemeDivider()
                ScheduledTasksView()
            }
        }
    }

    /// Follows the window when something else (a notification, search or the
    /// phone) opens one of an agent's threads.
    private func syncPageWithWindow() {
        guard let projectId = window.selectedProject?.id, let owner = state.agentOwning(projectId: projectId) else { return }
        if page != .agent(owner.agent.id) { page = .agent(owner.agent.id) }
    }

    private func newAgent() {
        let count = state.agentProfiles.count
        draft = AgentProfile(
            name: "",
            colorHex: AgentProfile.palette[count % AgentProfile.palette.count],
            petLookId: PetLook.builtins[count % PetLook.builtins.count].id
        )
    }

    private func delete(_ agent: AgentProfile) {
        deleting = nil
        status = String(localized: "Deleting \(agent.displayName)…")
        Task {
            await state.deleteAgent(id: agent.id)
            status = String(localized: "Agent deleted")
            try? await Task.sleep(for: .seconds(1.2))
            status = nil
        }
    }
}

enum AgentHubPage: Hashable {
    case team
    case agent(UUID)
    case schedules
}

enum AgentHubLayout {
    /// Shared by the sidebar and page headers so their dividers line up.
    static let headerHeight: CGFloat = 52
}

/// The top bar of an Agents page, with the sidebar toggle.
struct AgentPageHeader<Content: View, Trailing: View>: View {
    @Binding var sidebarVisible: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    init(
        sidebarVisible: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        _sidebarVisible = sidebarVisible
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help(sidebarVisible ? "Hide agents sidebar" : "Show agents sidebar")
            .accessibilityIdentifier("agent-hub-sidebar-toggle")
            content
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: AgentHubLayout.headerHeight)
    }
}

// MARK: - Sidebar

private struct AgentHubSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var page: AgentHubPage
    let onNew: () -> Void
    let onEdit: (AgentProfile) -> Void
    let onDelete: (AgentProfile) -> Void
    let onRemoteAccess: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents")
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("New Agent")
                .accessibilityLabel("New Agent")
            }
            .padding(.horizontal, 14)
            .frame(height: AgentHubLayout.headerHeight)

            ClaudeThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navigationRow(.team, title: "Team", systemImage: "person.3.sequence.fill", badge: activeCollaborations)

                    sectionHeader("Agents")
                    if state.agentProfiles.isEmpty {
                        Button(action: onNew) {
                            Label("Create your first agent", systemImage: "plus.circle")
                                .font(.system(size: ClaudeTheme.size(12)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ClaudeTheme.accent)
                    }
                    ForEach(state.agentProfiles) { agent in
                        agentRow(agent)
                    }

                    sectionHeader("Workspace")
                    navigationRow(.schedules, title: "Workspace Schedules", systemImage: "calendar.badge.clock", badge: 0)
                    Button(action: onRemoteAccess) {
                        rowLabel(title: "Remote Access", systemImage: "iphone.and.arrow.forward", badge: 0, selected: false)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity)
        .background(ClaudeTheme.sidebarBackground)
    }

    private var activeCollaborations: Int {
        state.agentCollaborations().filter(\.status.isActive).count
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func navigationRow(_ target: AgentHubPage, title: LocalizedStringKey, systemImage: String, badge: Int) -> some View {
        Button { page = target } label: {
            rowLabel(title: title, systemImage: systemImage, badge: badge, selected: page == target)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(title: LocalizedStringKey, systemImage: String, badge: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(selected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Spacer()
            if badge > 0 { countBadge(badge) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall).fill(selected ? ClaudeTheme.sidebarItemSelected : .clear))
        .contentShape(Rectangle())
    }

    private func agentRow(_ agent: AgentProfile) -> some View {
        let selected = page == .agent(agent.id)
        let activity = state.agentActivity(agent.id)
        let activeJobs = state.agentJobs(for: agent.id).filter(\.status.isActive).count
        return Button { page = .agent(agent.id) } label: {
            HStack(spacing: 10) {
                AgentAvatarView(agent: agent, activity: activity, size: 34, animated: selected || activity != .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(agent, activity: activity))
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(activity == .idle ? ClaudeTheme.textTertiary : ClaudeTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if activeJobs > 0 { countBadge(activeJobs) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall).fill(selected ? ClaudeTheme.sidebarItemSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-profile-\(agent.displayName)")
        .contextMenu {
            Button("Edit Agent…") { onEdit(agent) }
            Divider()
            Button("Delete Agent…", role: .destructive) { onDelete(agent) }
        }
    }

    private func subtitle(_ agent: AgentProfile, activity: AgentActivity) -> String {
        if activity != .idle { return String(localized: activity.label) }
        let summary = agent.roleSummary
        return summary.isEmpty ? agent.tone.displayNameText : summary
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: ClaudeTheme.size(10), weight: .semibold).monospacedDigit())
            .foregroundStyle(ClaudeTheme.textOnAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(ClaudeTheme.accent))
    }
}
