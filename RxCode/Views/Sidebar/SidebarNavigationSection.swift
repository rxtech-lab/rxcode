import RxCodeCore
import SwiftUI
import TipKit

// MARK: - SidebarNavigationSection

/// Top-of-sidebar navigation for the workspace-wide routes. Every route uses
/// the same row so the area reads as one list instead of a grid with a
/// leftover full-width entry.
struct SidebarNavigationSection: View {
    /// Display order: the two routes people switch between most come first.
    private static let routes: [GeneralRoute] = [.tasks, .chat, .briefing, .agents]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Self.routes, id: \.self) { route in
                if route == .briefing {
                    SidebarNavigationRow(route: route)
                        .popoverTip(RxCodeTips.BriefingTip(), arrowEdge: .trailing)
                } else {
                    SidebarNavigationRow(route: route)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - SidebarNavigationRow

private struct SidebarNavigationRow: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow

    let route: GeneralRoute
    @State private var isHovered = false

    private var isSelected: Bool {
        windowState.generalRoute == route && windowState.sidebarTreeSelection == nil
    }

    private var help: LocalizedStringKey {
        switch route {
        case .tasks: "Open the project task board"
        case .chat: "Chat with any agent"
        case .briefing: "Open project branch briefing"
        case .agents: "Open agents and schedules"
        case .scheduled: "Open tasks that run on a cron schedule"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: route.systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .frame(width: 18, height: 18)

                Text(route.displayName)
                    .font(.system(size: ClaudeTheme.size(13), weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                trailingAccessory
            }
            .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall, style: .continuous)
                    .fill(isSelected ? ClaudeTheme.accentSubtle : (isHovered ? ClaudeTheme.sidebarItemHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
        .accessibilityIdentifier("general-route-\(route.rawValue)")
        .contextMenu { contextMenu }
    }

    // MARK: Trailing accessory

    @ViewBuilder
    private var trailingAccessory: some View {
        switch route {
        case .chat:
            AttentionBadge(attention: appState.projectAttention(projectId: Project.globalChatID, in: windowState))
        case .tasks:
            countLabel(appState.projects.filter { !$0.isGlobalChat }.count, label: "projects")
        case .agents:
            countLabel(appState.agentProfiles.count, label: "agents")
        case .scheduled:
            countLabel(appState.scheduledTasks.filter(\.isEnabled).count, label: "enabled schedules")
        case .briefing:
            EmptyView()
        }
    }

    @ViewBuilder
    private func countLabel(_ count: Int, label: String) -> some View {
        if count > 0 {
            Text(count, format: .number)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textTertiary)
                .accessibilityLabel("\(count) \(label)")
        }
    }

    // MARK: Actions

    private func open() {
        if route == .chat {
            appState.openGlobalChat(in: windowState)
        } else {
            if route == .tasks { windowState.taskDetailProjectId = nil }
            windowState.generalRoute = route
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if route == .chat {
            Button {
                openWindow(
                    id: "chat-window",
                    value: ChatWindowValue(instanceId: UUID(), workspaceID: appState.activeWorkspace.id)
                )
            } label: {
                Label("Chat in New Window", systemImage: "macwindow.badge.plus")
            }
        } else {
            Button {
                openWindow(
                    id: "route-window",
                    value: GeneralRouteWindowValue(
                        route: route,
                        instanceId: UUID(),
                        workspaceID: appState.activeWorkspace.id
                    )
                )
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
    }
}
