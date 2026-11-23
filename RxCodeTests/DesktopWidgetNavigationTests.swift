import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class DesktopWidgetNavigationTests: XCTestCase {
    func testWidgetThreadsLookUpEachRemovedProjectOnce() {
        let current = Project(name: "Current", path: "/current")
        let global = Project(id: Project.globalChatID, name: "Chat", path: "/chat")
        let removed = Project(name: "Removed", path: "/removed")
        let unknown = UUID()
        let owners = [current.id, global.id, removed.id, unknown, removed.id, unknown]
        var summaries = owners.enumerated().map { ChatSession(id: String($0.offset), projectId: $0.element).summary }
        var archived = ChatSession(id: "archived", projectId: UUID()).summary
        archived.isArchived = true
        summaries.append(archived)
        let input = DesktopWidgetWorkspace(projects: [current], boards: [:], globalChat: global,
                                           summaries: summaries, streaming: ["2"])
        var queries: [UUID: Int] = [:]
        let threads = input.threads { id in
            queries[id, default: 0] += 1
            return id == removed.id ? removed : nil
        }
        XCTAssertEqual(queries, [removed.id: 1, unknown: 1])
        XCTAssertEqual(threads.map(\.id), ["0", "1", "2", "4"])
        XCTAssertEqual(threads.map(\.projectName), ["Current", "Chat", "Removed", "Removed"])
        XCTAssertEqual(threads.filter(\.isOngoing).map(\.id), ["2"])
    }

    func testTaskLinkNavigatesInSuppliedWindow() {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let project = Project(name: "Widget project", path: "/tmp/widget-project", gitHubRepo: nil)
        let task = ProjectTask(projectId: project.id, title: "Running task", status: .inProgress, sessionKey: "run")
        state.projects = [project]
        state.taskBoards[project.id] = TaskBoard(tasks: [task])
        let window = WindowState()
        window.generalRoute = .briefing
        let snapshot = DesktopWidgetSnapshot(workspaceID: state.activeWorkspace.id, workspaceName: "Test", projects: [], agents: [])

        XCTAssertTrue(state.handleDesktopWidgetURL(snapshot.url(projectID: project.id, taskID: task.id), in: window))
        XCTAssertEqual(window.generalRoute, .tasks)
        XCTAssertEqual(window.taskDetailProjectId, project.id)
        XCTAssertEqual(window.pendingTaskDetailId, task.id)

        // A stale widget opens the board without presenting a nonexistent task.
        XCTAssertTrue(state.handleDesktopWidgetURL(snapshot.url(projectID: project.id, taskID: UUID()), in: window))
        XCTAssertEqual(window.taskDetailProjectId, project.id)
        XCTAssertNil(window.pendingTaskDetailId)
    }

    func testOtherWorkspaceLinkDoesNotChangeWindow() {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let window = WindowState()
        window.generalRoute = .briefing
        let snapshot = DesktopWidgetSnapshot(workspaceID: "another-workspace", workspaceName: "Other", projects: [], agents: [])

        XCTAssertFalse(state.handleDesktopWidgetURL(snapshot.url(), in: window))
        XCTAssertEqual(window.generalRoute, .briefing)
        XCTAssertNil(window.taskDetailProjectId)
    }
}
