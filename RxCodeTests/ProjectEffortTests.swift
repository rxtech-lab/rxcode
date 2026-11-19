import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class ProjectEffortTests: XCTestCase {
    private var persistence: MockAppStatePersistence!
    private var appState: AppState!
    private var window: WindowState!
    private var selectedProjectId: String?

    override func setUp() async throws {
        selectedProjectId = UserDefaults.standard.string(forKey: "selectedProjectId")
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
        window = WindowState()
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(selectedProjectId, forKey: "selectedProjectId")
        window = nil
        appState = nil
        persistence = nil
    }

    func testEffortSelectionIsRememberedPerProject() async throws {
        let first = makeProject("First")
        let second = makeProject("Second")
        appState.projects = [first, second]

        appState.selectProject(first, in: window)
        appState.setSessionEffort("high", in: window)
        appState.selectProject(second, in: window)
        XCTAssertNil(window.sessionEffort)
        appState.setSessionEffort("medium", in: window)
        appState.selectProject(first, in: window)
        XCTAssertEqual(window.sessionEffort, "high")

        try await Task.sleep(for: .milliseconds(50))
        let saved = await persistence.loadProjects()
        XCTAssertEqual(saved.map(\.lastEffort), ["high", "medium"])
        let data = try JSONEncoder().encode(saved)
        let reopened = AppState(persistence: persistence, startBackgroundServices: false)
        reopened.projects = try JSONDecoder().decode([Project].self, from: data)
        let reopenedWindow = WindowState()
        reopened.selectProject(try XCTUnwrap(reopened.projects.last), in: reopenedWindow)
        XCTAssertEqual(reopenedWindow.sessionEffort, "medium")

        appState.setSessionEffort(nil, in: window)
        appState.startNewChat(in: window)
        XCTAssertNil(window.sessionEffort)
        XCTAssertEqual(appState.projects.map(\.lastEffort), [nil, "medium"])
    }

    func testIncompatibleModelDoesNotEraseRememberedProjectEffort() {
        let project = makeProject("Project")
        appState.projects = [project]
        window.selectedProject = project
        appState.codexLevelsByModel = ["gpt-5.4": .levels(["high", "xhigh"]), "gpt-5.4-mini": .levels(["high"])]

        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        appState.setSessionEffort("xhigh", in: window)
        appState.setSessionModel("gpt-5.4-mini", provider: .codex, in: window)
        appState.reconcileSessionEffort(in: window, provider: .codex)
        XCTAssertNil(window.sessionEffort)
        XCTAssertEqual(appState.projects.first?.lastEffort, "xhigh")

        appState.startNewChat(in: window)
        XCTAssertNil(window.sessionEffort)
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        appState.startNewChat(in: window)
        XCTAssertEqual(window.sessionEffort, "xhigh")
    }

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())")
    }
}
