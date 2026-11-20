import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class ProjectEffortTests: XCTestCase {
    private var persistence: MockAppStatePersistence!
    private var appState: AppState!
    private var window: WindowState!
    private var workspaceDefaults: WorkspaceDefaults!

    override func setUp() async throws {
        workspaceDefaults = WorkspaceDefaults(workspaceID: UUID().uuidString)
        persistence = MockAppStatePersistence()
        appState = makeAppState()
        appState.selectedAgentProvider = .codex
        appState.selectedModel = "gpt-5.4"
        appState.codexLevelsByModel = [
            "gpt-5.4": .levels(["low", "medium", "high", "xhigh"]),
            "gpt-5.4-mini": .levels(["low", "medium", "high"]),
        ]
        window = WindowState()
    }

    override func tearDown() async throws {
        await appState.projectChatPreferencesSaveTask?.value
        for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix(workspaceDefaults.key("")) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        window = nil
        appState = nil
        persistence = nil
    }

    func testEffortSelectionIsRememberedPerProjectAndModel() async throws {
        let first = makeProject("First")
        let second = makeProject("Second")
        appState.projects = [first, second]

        appState.selectProject(first, in: window)
        appState.setSessionEffort("high", in: window)
        appState.setSessionModel("gpt-5.4-mini", provider: .codex, in: window)
        XCTAssertNil(effort, "A model starts with Default even if it supports the previous model's level")
        appState.setSessionEffort("low", in: window)
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        XCTAssertEqual(effort, "high")

        appState.selectProject(second, in: window)
        XCTAssertNil(effort)
        appState.setSessionEffort("medium", in: window)
        appState.selectProject(first, in: window)
        XCTAssertEqual(effort, "high")
        appState.setSessionModel("gpt-5.4-mini", provider: .codex, in: window)
        appState.startNewChat(in: window)
        XCTAssertEqual(effort, "low")

        await appState.projectChatPreferencesSaveTask?.value
        let saved = await persistence.loadProjects()
        let data = try JSONEncoder().encode(saved)
        let reopened = makeAppState()
        reopened.projects = try JSONDecoder().decode([Project].self, from: data)
        let reopenedWindow = WindowState()
        reopened.selectProject(try XCTUnwrap(reopened.projects.first), in: reopenedWindow)
        XCTAssertEqual(reopened.effectiveSessionEffort(in: reopenedWindow), "low")
        reopened.setSessionModel("gpt-5.4", provider: .codex, in: reopenedWindow)
        XCTAssertEqual(reopened.effectiveSessionEffort(in: reopenedWindow), "high")
        reopened.selectProject(try XCTUnwrap(reopened.projects.last), in: reopenedWindow)
        XCTAssertEqual(reopened.effectiveSessionEffort(in: reopenedWindow), "medium")
        await reopened.projectChatPreferencesSaveTask?.value
    }

    func testDefaultClearsOnlyTheCurrentModelsSelection() async {
        let project = makeProject("Project")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        appState.setSessionEffort("high", in: window)
        appState.setSessionModel("gpt-5.4-mini", provider: .codex, in: window)
        appState.setSessionEffort("low", in: window)

        let handled = await appState.handleNativeSlashCommand("/effort auto", in: window)
        XCTAssertTrue(handled)
        XCTAssertNil(effort)
        appState.startNewChat(in: window)
        XCTAssertNil(effort)
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        XCTAssertEqual(effort, "high")
    }

    func testUnavailableLevelIsRetainedForItsModel() {
        let project = makeProject("Project")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        appState.setSessionEffort("xhigh", in: window)

        appState.codexLevelsByModel["gpt-5.4"] = .levels(["high"])
        XCTAssertNil(effort)
        appState.codexLevelsByModel["gpt-5.4"] = .levels(["high", "xhigh"])
        XCTAssertEqual(effort, "xhigh")
    }

    func testIdenticalModelIDsHaveSeparatePreferencesAcrossProviders() {
        let project = makeProject("Project")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        appState.setSessionEffort("high", in: window)

        appState.setSessionModel("gpt-5.4", provider: .claudeCode, in: window)
        XCTAssertNil(effort)
        appState.setSessionEffort("low", in: window)
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        XCTAssertEqual(effort, "high")
        appState.setSessionModel("gpt-5.4", provider: .claudeCode, in: window)
        XCTAssertEqual(effort, "low")
    }

    func testModelSwitchInExistingChatPersistsDefaultInsteadOfThePreviousLevel() async throws {
        let project = makeProject("Project")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        appState.setSessionEffort("high", in: window)
        let messages = [ChatMessage(role: .user, content: "Previous prompt")]
        let session = ChatSession(
            id: UUID().uuidString, projectId: project.id, title: "Existing chat", messages: messages,
            agentProvider: .codex, model: "gpt-5.4", effort: "medium", origin: .codexAppServer
        )
        appState.allSessionSummaries = [session.summary]
        appState.switchToSession(session, messages: messages, in: window)
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        XCTAssertEqual(effort, "medium")

        appState.setSessionModel("gpt-5.4-mini", provider: .codex, in: window)
        appState.switchToSession(session, messages: messages, in: window)
        XCTAssertNil(effort)
        await appState.saveCurrentSession(in: window)
        let savedSessions = await persistence.savedSessions()
        let saved = try XCTUnwrap(savedSessions.last?.session)
        XCTAssertEqual(saved.model, "gpt-5.4-mini")
        XCTAssertNil(saved.effort)
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        XCTAssertEqual(effort, "high")
    }

    func testLegacyProjectEffortIsMigratedToOneModel() async throws {
        let recorded = Project(name: "Recorded", path: "/tmp/recorded",
                               lastAgentProvider: .codex, lastModel: "gpt-5.4-mini", lastEffort: "low")
        let implicit = Project(name: "Implicit", path: "/tmp/implicit", lastEffort: "high")
        let legacy = try JSONDecoder().decode([Project].self, from: JSONEncoder().encode([recorded, implicit]))
        try await persistence.saveProjects(legacy)
        appState.projects = await appState.loadDeduplicatedProjects()
        let migrated = await persistence.loadProjects()
        XCTAssertEqual(migrated.count, 2)
        XCTAssertTrue(migrated.allSatisfy { $0.lastEffort == nil })

        appState.selectProject(recorded, in: window)
        XCTAssertEqual(effort, "low")
        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        XCTAssertNil(effort)
        appState.selectProject(implicit, in: window)
        XCTAssertEqual(effort, "high")
        appState.selectedModel = "gpt-5.4-mini"
        XCTAssertNil(effort)
        appState.selectedModel = "gpt-5.4"
        XCTAssertEqual(effort, "high")
    }

    func testComposerSendsRememberedLevelOrSettingsDefaultForItsModel() async throws {
        let project = makeProject("Project")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        appState.selectedEffort = "medium"
        appState.memoryEnabled = false
        let backend = MockAgentBackend(provider: .codex)
        appState.agentBackendOverrides[.codex] = backend

        let handled = await appState.handleNativeSlashCommand("/effort high", in: window)
        XCTAssertTrue(handled)
        try await sendMessage("Use remembered effort")
        appState.startNewChat(in: window)
        appState.setSessionModel("gpt-5.4-mini", provider: .codex, in: window)
        try await sendMessage("Use Settings effort")

        let requests = await backend.receivedRequests
        XCTAssertEqual(requests.map(\.model), ["gpt-5.4", "gpt-5.4-mini"])
        XCTAssertEqual(requests.map(\.effort), ["high", "medium"])
    }

    func testGlobalChatKeepsItsOwnModelPreferencesAcrossLaunches() {
        let project = makeProject("Project")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        appState.setSessionEffort("high", in: window)
        appState.openGlobalChat(in: window)
        XCTAssertNil(effort)
        appState.setSessionEffort("low", in: window)

        let reopened = makeAppState()
        let reopenedWindow = WindowState()
        reopened.openGlobalChat(in: reopenedWindow)
        XCTAssertEqual(reopened.effectiveSessionEffort(in: reopenedWindow), "low")
        appState.selectProject(project, in: window)
        XCTAssertEqual(effort, "high")
    }

    private var effort: String? { appState.effectiveSessionEffort(in: window) }

    private func makeAppState() -> AppState {
        let state = AppState(persistence: persistence, startBackgroundServices: false)
        state.workspaceDefaults = workspaceDefaults
        state.loadWorkspaceSettings()
        return state
    }

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())")
    }

    private func sendMessage(_ text: String) async throws {
        window.inputText = text
        await appState.send(in: window)
        let sessionId = try XCTUnwrap(window.currentSessionId)
        let streamId = try XCTUnwrap(appState.stateForSession(sessionId).activeStreamId)
        let completion = await appState.awaitStreamCompletion(streamId: streamId, timeout: 10, acceptsPartial: false)
        XCTAssertNotNil(completion)
        XCTAssertNil(completion?.error)
    }
}
