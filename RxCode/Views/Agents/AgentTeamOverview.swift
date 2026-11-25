import RxCodeCore
import SwiftUI

/// The team page: every agent as an animated card, and the requests agents
/// sent each other.
struct AgentTeamOverview: View {
    @Environment(AppState.self) private var state
    @Environment(WindowState.self) private var window
    @Binding var sidebarVisible: Bool
    let onSelect: (UUID) -> Void
    let onNew: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            AgentPageHeader(sidebarVisible: $sidebarVisible) {
                Label("Team", systemImage: "person.3.sequence.fill")
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
            } trailing: {
                Button("New Agent", systemImage: "plus", action: onNew)
                    .buttonStyle(.borderless)
            }
            ClaudeThemeDivider()
            if state.agentProfiles.isEmpty {
                ContentUnavailableView {
                    Label("No Agents Yet", systemImage: "person.3.sequence")
                } description: {
                    Text("Agents are long-lived helpers with their own look, personality, memory and schedules. They can ask each other for help.")
                } actions: {
                    Button("New Agent", action: onNew)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(state.agentProfiles) { agent in
                                AgentCard(agent: agent) { onSelect(agent.id) }
                            }
                        }
                        collaborationFeed
                    }
                    .padding(22)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var collaborationFeed: some View {
        let requests = state.agentCollaborations()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Collaboration", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
            }
            if requests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.agentProfiles.count > 1
                        ? "No requests between agents yet."
                        : "Create a second agent so they can work together.")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Text("Agents ask teammates for help on their own when the work fits a teammate better. You can also ask in chat, for example “Ask Researcher to compare these options.”")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).fill(ClaudeTheme.surfacePrimary))
                .overlay(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).strokeBorder(ClaudeTheme.borderSubtle))
            } else {
                VStack(spacing: 0) {
                    ForEach(requests.prefix(40)) { job in
                        AgentCollaborationRow(job: job) { open(job) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).fill(ClaudeTheme.surfacePrimary))
                .overlay(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium).strokeBorder(ClaudeTheme.borderSubtle))
            }
        }
    }

    /// Opens the teammate's reply thread, which also selects that agent.
    private func open(_ job: AgentJob) {
        if let session = job.sessionKey, let target = job.targetAgentId, state.agentProfile(id: target) != nil {
            let alreadyInProject = window.selectedProject?.id == target
            state.openAgentThread(state.resolveCurrentSessionId(session), in: window)
            // Switching projects is asynchronous; the hub follows the window
            // once it lands, so only select directly when no switch happens.
            if alreadyInProject { onSelect(target) }
        } else if state.agentProfile(id: job.agentId) != nil {
            onSelect(job.agentId)
        }
    }
}

private struct AgentCard: View {
    @Environment(AppState.self) private var state
    let agent: AgentProfile
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let activity = state.agentActivity(agent.id)
        let activeJobs = state.agentJobs(for: agent.id).filter(\.status.isActive).count
        Button(action: action) {
            VStack(spacing: 10) {
                AgentAvatarView(agent: agent, activity: activity, size: 92)
                    .padding(.top, 6)
                VStack(spacing: 3) {
                    Text(agent.displayName)
                        .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    Text(agent.roleSummary.isEmpty ? agent.tone.displayNameText : agent.roleSummary)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 6) {
                    AgentActivityPill(activity: activity)
                    if activeJobs > 0 {
                        Label("\(activeJobs)", systemImage: "tray.full")
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .fill(LinearGradient(
                        colors: [Color(hex: agent.colorHex).opacity(hovering ? 0.16 : 0.10), ClaudeTheme.surfacePrimary],
                        startPoint: .top, endPoint: .bottom
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .strokeBorder(hovering ? Color(hex: agent.colorHex).opacity(0.5) : ClaudeTheme.borderSubtle)
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "Chat with \(agent.displayName)"))
        .accessibilityIdentifier("agent-card-\(agent.displayName)")
    }
}
