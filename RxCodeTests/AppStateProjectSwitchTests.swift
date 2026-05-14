import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class AppStateProjectSwitchTests: XCTestCase {

    private var appState: AppState!
    private var window: WindowState!

    override func setUp() async throws {
        appState = AppState()
        window = WindowState()
    }

    override func tearDown() async throws {
        appState = nil
        window = nil
    }

    // MARK: - selectProject: basic navigation

    func testSelectProject_updatesSelectedProject() {
        let projectA = makeProject("A")
        let projectB = makeProject("B")
        appState.projects = [projectA, projectB]
        window.selectedProject = projectA

        appState.selectProject(projectB, in: window)

        XCTAssertEqual(window.selectedProject?.id, projectB.id)
    }

    func testSelectProject_clearsCurrentSessionId() {
        let projectA = makeProject("A")
        let projectB = makeProject("B")
        appState.projects = [projectA, projectB]
        window.selectedProject = projectA
        window.currentSessionId = "old-session"

        appState.selectProject(projectB, in: window)

        XCTAssertNil(window.currentSessionId)
    }

    func testSelectProject_sameProject_isNoOp() {
        let projectA = makeProject("A")
        appState.projects = [projectA]
        window.selectedProject = projectA
        window.currentSessionId = "sentinel"

        appState.selectProject(projectA, in: window)

        // Early return: nothing should change
        XCTAssertEqual(window.currentSessionId, "sentinel")
    }

    // MARK: - selectProject: sessionStates cleanup (core behaviour under test)

    func testSelectProject_removesNonStreamingSessionStates() {
        let projectA = makeProject("A")
        let projectB = makeProject("B")
        appState.projects = [projectA, projectB]
        window.selectedProject = projectA

        var idle = SessionStreamState()
        idle.isStreaming = false
        appState.sessionStates["idle-key"] = idle

        appState.selectProject(projectB, in: window)

        XCTAssertNil(appState.sessionStates["idle-key"],
                     "Non-streaming state should be evicted on project switch")
    }

    func testSelectProject_preservesStreamingSessionStates() {
        let projectA = makeProject("A")
        let projectB = makeProject("B")
        appState.projects = [projectA, projectB]
        window.selectedProject = projectA

        var bg = SessionStreamState()
        bg.isStreaming = true
        appState.sessionStates["bg-stream"] = bg

        appState.selectProject(projectB, in: window)

        XCTAssertNotNil(appState.sessionStates["bg-stream"],
                        "In-flight streaming state must survive project switch")
    }

    func testSelectProject_removesMultipleIdleStates_inOnePass() {
        let projectA = makeProject("A")
        let projectB = makeProject("B")
        appState.projects = [projectA, projectB]
        window.selectedProject = projectA

        for i in 0..<5 {
            var state = SessionStreamState()
            state.isStreaming = false
            appState.sessionStates["idle-\(i)"] = state
        }
        var streaming = SessionStreamState()
        streaming.isStreaming = true
        appState.sessionStates["live"] = streaming

        appState.selectProject(projectB, in: window)

        let idleCount = (0..<5).filter { appState.sessionStates["idle-\($0)"] != nil }.count
        XCTAssertEqual(idleCount, 0)
        XCTAssertNotNil(appState.sessionStates["live"])
    }

    // MARK: - Helpers

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())", gitHubRepo: nil)
    }
}
