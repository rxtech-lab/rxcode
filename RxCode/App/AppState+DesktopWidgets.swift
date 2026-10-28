import Foundation
import RxCodeCore
import WidgetKit

extension AppState {
    /// Coalesce board changes and only publish the workspace shown in global UI.
    func scheduleDesktopWidgetUpdate() {
        guard !AppSupport.isTestProcess, isInitialized, desktopWidgetUpdateTask == nil else { return }
        desktopWidgetUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.desktopWidgetUpdateTask = nil
            guard self.desktopWidgetsActive else { return }
            let snapshot = DesktopWidgetSnapshot(
                workspaceID: self.activeWorkspace.id,
                workspaceName: self.activeWorkspace.name,
                projects: self.projects.map { WidgetProject(id: $0.id, name: $0.name, board: self.taskBoard(for: $0.id)) },
                agents: [
                    WidgetAgentUsage(id: "claude", name: "Claude Code", usage: self.latestRateLimitUsage, measuredAt: self.desktopClaudeUsageDate),
                    WidgetAgentUsage(id: "codex", name: "Codex", usage: self.latestCodexRateLimitUsage, measuredAt: self.desktopCodexUsageDate)
                ] + self.acpClients.filter(\.enabled).map {
                    WidgetAgentUsage(id: "acp:\($0.id)", name: $0.displayName, usage: nil, supportsLimits: false)
                },
                threads: self.allSessionSummaries.filter { !$0.isArchived }.compactMap { summary in
                    guard let project = self.sessionProject(id: summary.projectId) else { return nil }
                    return WidgetThread(id: summary.id, projectID: project.id, projectName: project.name,
                        title: summary.title, isOngoing: self.sessionActivity[summary.id]?.isStreaming ?? false,
                        updatedAt: summary.updatedAt)
                },
                usageDashboard: self.usageDashboard
            )
            await DesktopWidgetPublisher.shared.publish(snapshot)
        }
    }

    func handleDesktopWidgetURL(_ url: URL, in window: WindowState) -> Bool {
        guard url.scheme == "rxcode", url.host == "widget",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "workspace" })?.value == activeWorkspace.id else { return false }
        if url.path == "/usage" {
            window.generalRoute = .briefing
        } else if url.path == "/thread" {
            guard let threadID = components.queryItems?.first(where: { $0.name == "thread" })?.value,
                  allSessionSummaries.contains(where: { $0.id == threadID && !$0.isArchived }) else { return false }
            selectSession(id: threadID, in: window)
        } else if url.path == "/tasks" {
            window.generalRoute = .tasks
            let id = components.queryItems?.first(where: { $0.name == "project" })?.value.flatMap(UUID.init(uuidString:))
            window.taskDetailProjectId = projects.first(where: { $0.id == id })?.id
            let taskID = components.queryItems?.first(where: { $0.name == "task" })?.value.flatMap(UUID.init(uuidString:))
            window.pendingTaskDetailId = window.taskDetailProjectId.flatMap { projectID in
                taskBoard(for: projectID).tasks.first(where: { $0.id == taskID })?.id
            }
        } else { return false }
        return true
    }
}

private actor DesktopWidgetPublisher {
    static let shared = DesktopWidgetPublisher()
    func publish(_ snapshot: DesktopWidgetSnapshot) {
        do {
            try DesktopWidgetStore.save(snapshot)
            for kind in ["RxCodeProjectTasks", "RxCodeOngoingTasks", "RxCodeAgentUsage", "RxCodeIntegrationUsage"] {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            }
        } catch {
            // Keep the previous complete snapshot if encoding fails.
        }
    }
}
