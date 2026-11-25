import Foundation
import RxCodeCore

extension AppState {
    /// Uses the existing session pipeline without adding a repository or task board.
    /// Each workspace owns its own transcripts and agent working directory.
    var globalChatProject: Project {
        Project(
            id: Project.globalChatID,
            name: String(localized: "Chat"),
            path: activeWorkspace.storageURL.appendingPathComponent("global-chat", isDirectory: true).path
        )
    }

    /// Every project a thread can belong to: repositories, Chat, and the
    /// conversation and subagent projects of each agent.
    var sessionProjects: [Project] { projects + [globalChatProject] + agentVirtualProjects }

    func sessionProject(id: UUID) -> Project? {
        if id == Project.globalChatID { return globalChatProject }
        if let project = projects.first(where: { $0.id == id }) { return project }
        if let project = agentVirtualProject(id: id) { return project }
        return threadStore.retainedProject(id: id)
    }

    /// Search follows stored chats, including those whose projects were removed.
    func globalSearchGroups(
        _ results: [ThreadSearchService.Group],
        excluding currentThreadId: String?
    ) -> [ThreadSearchService.Group] {
        let sessionIds = Set(allSessionSummaries.map(\.id))
        return results.compactMap { group in
            let hits = group.hits.filter {
                sessionIds.contains($0.threadId) && $0.threadId != currentThreadId
            }
            guard !hits.isEmpty else { return nil }
            return ThreadSearchService.Group(projectId: group.projectId, hits: hits)
        }
    }

    func openGlobalChat(in window: WindowState) {
        window.cancelSessionSwitchTask()
        selectProject(globalChatProject, in: window)
        window.generalRoute = .chat
        window.requestInputFocus = true
    }

    func startNewGlobalChat(in window: WindowState) {
        openGlobalChat(in: window)
        startNewChat(in: window)
    }
}
