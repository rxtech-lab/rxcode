import Foundation
import RxCodeCore
import SwiftData
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
            let agents = [
                WidgetAgentUsage(id: "claude", name: "Claude Code", usage: self.latestRateLimitUsage, measuredAt: self.desktopClaudeUsageDate),
                WidgetAgentUsage(id: "codex", name: "Codex", usage: self.latestCodexRateLimitUsage, measuredAt: self.desktopCodexUsageDate)
            ] + self.acpClients.filter(\.enabled).map {
                WidgetAgentUsage(id: "acp:\($0.id)", name: $0.displayName, usage: nil, supportsLimits: false)
            }
            let input = DesktopWidgetWorkspace(
                projects: self.projects, boards: self.taskBoards, globalChat: self.globalChatProject,
                summaries: self.allSessionSummaries,
                streaming: Set(self.sessionActivity.compactMap { $0.value.isStreaming ? $0.key : nil })
            )
            await DesktopWidgetPublisher.shared.publish(
                workspaceID: self.activeWorkspace.id, name: self.activeWorkspace.name,
                input: input, agents: agents, usage: self.usageDashboard, container: self.threadStore.container
            )
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

/// Value snapshot of the workspace. The publisher projects rows using its own SwiftData context.
nonisolated struct DesktopWidgetWorkspace {
    let projects: [Project]
    let boards: [UUID: TaskBoard]
    let globalChat: Project
    let summaries: [ChatSession.Summary]
    let streaming: Set<String>

    func threads(retainedProject: (UUID) -> Project?) -> [WidgetThread] {
        var names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        names[globalChat.id] = globalChat.name
        let visible = summaries.lazy.filter { !$0.isArchived }
        for id in Set(visible.map(\.projectId)).subtracting(names.keys) {
            names[id] = retainedProject(id)?.name
        }
        return visible.compactMap { summary in
            guard let name = names[summary.projectId] else { return nil }
            return WidgetThread(id: summary.id, projectID: summary.projectId, projectName: name,
                                title: summary.title, isOngoing: streaming.contains(summary.id), updatedAt: summary.updatedAt)
        }
    }
}

private actor DesktopWidgetPublisher {
    static let shared = DesktopWidgetPublisher()
    func publish(
        workspaceID: String, name: String, input: DesktopWidgetWorkspace, agents: [WidgetAgentUsage],
        usage: UsageDashboard?, container: ModelContainer
    ) {
        // Most workspaces have no removed projects, so open a context only on demand.
        lazy var context = ModelContext(container)
        let snapshot = DesktopWidgetSnapshot(
            workspaceID: workspaceID, workspaceName: name,
            projects: input.projects.map { WidgetProject(id: $0.id, name: $0.name, board: input.boards[$0.id] ?? TaskBoard()) },
            agents: agents,
            threads: input.threads { ThreadStore.retainedProject(id: $0, in: context) },
            usageDashboard: usage
        )
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
