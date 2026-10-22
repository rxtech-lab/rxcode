import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class DesktopWidgetNavigationTests: XCTestCase {
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
