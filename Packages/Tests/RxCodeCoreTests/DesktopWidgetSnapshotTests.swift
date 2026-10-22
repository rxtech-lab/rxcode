import Foundation
import Testing
@testable import RxCodeCore

@Suite("Desktop widget snapshots")
struct DesktopWidgetSnapshotTests {
    @Test("Ongoing excludes queued and interrupted tasks, including custom columns")
    func ongoingTasks() {
        let projectID = UUID()
        let running = TaskStatus(rawValue: "custom-running")
        let board = TaskBoard(tasks: [
            ProjectTask(projectId: projectID, title: "Running", status: running, sessionKey: "run"),
            ProjectTask(projectId: projectID, title: "Queued", status: running, sessionKey: "queue", isQueued: true),
            ProjectTask(projectId: projectID, title: "Interrupted", status: running, sessionKey: "old", attentionReason: "Interrupted"),
            ProjectTask(projectId: projectID, title: "Unassigned", status: running)
        ], columns: [TaskColumn(id: running, name: "Agent working", triggersChat: true)])
        let project = WidgetProject(id: projectID, name: "Project", board: board)
        #expect(project.ongoingCount == 1)
        #expect(project.tasks.first?.title == "Running")
        #expect(project.tasks.first?.status == "Agent working")
    }

    @Test("Story progress uses custom done columns")
    func storyProgress() {
        let id = UUID()
        let story = ProjectStory(projectId: id, title: "Ship")
        let complete = TaskStatus(rawValue: "shipped")
        let board = TaskBoard(stories: [story], tasks: [
            ProjectTask(projectId: id, storyId: story.id, title: "Complete", status: complete),
            ProjectTask(projectId: id, storyId: story.id, title: "Pending")
        ], columns: [TaskColumn(id: complete, name: "Shipped", countsAsDone: true), TaskColumn(id: .pending, name: "Pending")])
        let project = WidgetProject(id: id, name: "Project", board: board)
        #expect(project.stories.first?.doneCount == 1)
        #expect(project.stories.first?.taskCount == 2)
        #expect(project.openCount == 1)
    }

    @Test("Snapshot round trips with unavailable ACP usage and measurement dates")
    func roundTrip() throws {
        let snapshot = DesktopWidgetSnapshot(workspaceID: "workspace", workspaceName: "Work", projects: [], agents: [
            WidgetAgentUsage(id: "acp:client", name: "Client", usage: nil, supportsLimits: false),
            WidgetAgentUsage(id: "codex", name: "Codex", usage: RateLimitUsage(fiveHourPercent: 20, sevenDayPercent: 30, fiveHourResetsAt: nil, sevenDayResetsAt: nil), measuredAt: .now)
        ])
        #expect(try JSONDecoder().decode(DesktopWidgetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test("Deep links retain workspace, project, and task identities")
    func links() {
        let id = UUID()
        let taskID = UUID()
        let snapshot = DesktopWidgetSnapshot(workspaceID: "work & space", workspaceName: "Work", projects: [], agents: [])
        let components = URLComponents(url: snapshot.url(projectID: id, taskID: taskID), resolvingAgainstBaseURL: false)!
        #expect(components.host == "widget")
        #expect(components.path == "/tasks")
        #expect(components.queryItems?.first(where: { $0.name == "workspace" })?.value == "work & space")
        #expect(components.queryItems?.first(where: { $0.name == "project" })?.value == id.uuidString)
        #expect(components.queryItems?.first(where: { $0.name == "task" })?.value == taskID.uuidString)
        #expect(URLComponents(url: snapshot.url(projectID: id), resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "task" }) == false)
        #expect(snapshot.url(usage: true).path == "/usage")
    }
}
