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

    @Test("Recent finished tasks reserve space and respect project and time filters")
    func recentFinishedTasks() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shipped = TaskStatus(rawValue: "shipped")
        let board = TaskBoard(tasks: [
            ProjectTask(projectId: id, title: "Running", status: .inProgress, sessionKey: "run"),
            ProjectTask(projectId: id, title: "Pending"),
            ProjectTask(projectId: id, title: "Older", status: shipped, updatedAt: now.addingTimeInterval(-100)),
            ProjectTask(projectId: id, title: "Newest", status: shipped, updatedAt: now),
            ProjectTask(projectId: id, title: "Expired", status: shipped, updatedAt: now.addingTimeInterval(-8 * 86400))
        ], columns: [TaskColumn(id: .inProgress, name: "Running", triggersChat: true),
                     TaskColumn(id: .pending, name: "Pending"),
                     TaskColumn(id: shipped, name: "Shipped", countsAsDone: true)])
        let snapshot = DesktopWidgetSnapshot(workspaceID: "work", workspaceName: "Work",
            projects: [WidgetProject(id: id, name: "Project", board: board)], agents: [])
        #expect(snapshot.taskRows(limit: 2, now: now).map(\.task.title) == ["Running", "Newest"])
        #expect(snapshot.taskRows(ongoingOnly: true, limit: 5, now: now).map(\.task.title) == ["Running", "Newest", "Older"])
        #expect(snapshot.taskRows(projectID: UUID(), limit: 5, now: now).isEmpty)
        #expect(snapshot.taskRows(limit: 0, now: now).isEmpty)
        #expect(snapshot.taskRows(limit: 5, now: now.addingTimeInterval(8 * 86400)).allSatisfy { !$0.task.isDone })
    }

    @Test("Older widget tasks decode without an update timestamp")
    func legacyTask() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Old task","status":"Done","isOngoing":false,"isDone":true,"isQueued":false}
        """
        let task = try JSONDecoder().decode(WidgetTask.self, from: Data(json.utf8))
        #expect(task.updatedAt == nil)
    }

    @Test("Threads reserve recent stopped rows and filter stale activity and projects")
    func threadActivity() throws {
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000)
        func thread(_ id: String, ongoing: Bool, age: Double, project: UUID? = nil) -> WidgetThread {
            WidgetThread(id: id, projectID: project ?? projectID, projectName: "Project", title: id,
                isOngoing: ongoing, updatedAt: now.addingTimeInterval(-age))
        }
        let snapshot = DesktopWidgetSnapshot(workspaceID: "work", workspaceName: "Work", projects: [], agents: [], threads: [
            thread("running-old", ongoing: true, age: 9 * 86400),
            thread("running-new", ongoing: true, age: 1),
            thread("stopped-old", ongoing: false, age: 9 * 86400),
            thread("stopped-new", ongoing: false, age: 2),
            thread("other-project", ongoing: false, age: 0, project: UUID())
        ])
        #expect(snapshot.threadRows(projectID: projectID, limit: 2, now: now).map(\.id) == ["running-new", "stopped-new"])
        #expect(snapshot.threadRows(projectID: projectID, limit: 5, now: now).map(\.id) == ["running-new", "running-old", "stopped-new"])
        #expect(snapshot.threadRows(limit: 0, now: now).isEmpty)
        let restored = try JSONDecoder().decode(DesktopWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored == snapshot)
        let components = URLComponents(url: snapshot.url(projectID: projectID, threadID: "chat / & ?"), resolvingAgainstBaseURL: false)!
        #expect(components.path == "/thread")
        #expect(components.queryItems?.first(where: { $0.name == "thread" })?.value == "chat / & ?")
    }

    @Test("Snapshots written before chat support remain readable")
    func legacySnapshot() throws {
        let json = """
        {"workspaceID":"work","workspaceName":"Work","projects":[],"agents":[],"updatedAt":0}
        """
        let snapshot = try JSONDecoder().decode(DesktopWidgetSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.threads == nil)
        #expect(snapshot.threadRows(limit: 5, now: .now).isEmpty)
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
