import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class GlobalChatTests: XCTestCase {
    private var persistence: MockAppStatePersistence!
    private var appState: AppState!
    private var window: WindowState!
    private var defaultsSnapshot: [String: Any?] = [:]

    override func setUp() async throws {
        defaultsSnapshot = [
            "selectedAgentProvider": UserDefaults.standard.object(forKey: "selectedAgentProvider"),
            "selectedModel": UserDefaults.standard.object(forKey: "selectedModel"),
            "selectedACPClientId": UserDefaults.standard.object(forKey: "selectedACPClientId"),
            "memoryMaxContextItems": UserDefaults.standard.object(forKey: "memoryMaxContextItems"),
        ]
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
        window = WindowState()
    }

    override func tearDown() async throws {
        for (key, value) in defaultsSnapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        window = nil
        appState = nil
        persistence = nil
    }

    // MARK: - Global chat

    func testGlobalChatOpensWithoutRegisteringAProject() {
        appState.projects = []
        appState.openGlobalChat(in: window)

        XCTAssertEqual(window.generalRoute, .chat)
        XCTAssertEqual(window.selectedProject?.id, Project.globalChatID)
        XCTAssertEqual(window.selectedProject?.path, appState.activeWorkspace.storageURL.appendingPathComponent("global-chat").path)
        XCTAssertTrue(appState.projects.isEmpty)
        XCTAssertTrue(window.requestInputFocus)
        XCTAssertNil(window.currentSessionId)
    }

    func testGlobalChatKeepsProjectAndGlobalDraftsSeparate() {
        let project = makeProject("Repository")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        window.inputText = "Repository draft"

        appState.openGlobalChat(in: window)
        XCTAssertEqual(window.inputText, "")
        window.inputText = "Global draft"

        appState.selectProject(project, in: window)
        XCTAssertNil(window.generalRoute)
        XCTAssertEqual(window.inputText, "Repository draft")

        appState.openGlobalChat(in: window)
        XCTAssertEqual(window.inputText, "Global draft")
        appState.startNewChat(in: window)
        XCTAssertEqual(window.generalRoute, .chat)
        XCTAssertEqual(window.selectedProject?.id, Project.globalChatID)
    }

    func testGlobalChatUsesAllAgentProviders() {
        appState.openGlobalChat(in: window)
        for provider in [AgentProvider.claudeCode, .codex, .acp] {
            appState.setSessionModel("test-model", provider: provider, in: window)
            XCTAssertEqual(appState.effectiveModelSelection(in: window).provider, provider)
            XCTAssertEqual(appState.effectiveModelSelection(in: window).model, "test-model")
        }
    }

    func testGlobalChatStreamsAndResumesWithEveryProvider() async throws {
        appState.memoryEnabled = false
        appState.acpClients = [ACPClientSpec(
            id: "global-chat-test", displayName: "Test Agent",
            launch: .binary(path: "/usr/bin/true", args: [], env: [:]),
            models: ["test-model"]
        )]
        appState.openGlobalChat(in: window)
        let cwd = appState.globalChatProject.path

        for provider in [AgentProvider.claudeCode, .codex, .acp] {
            appState.startNewChat(in: window)
            let backend = MockAgentBackend(provider: provider)
            appState.agentBackendOverrides[provider] = backend
            appState.setSessionModel(
                provider == .acp ? "global-chat-test::test-model" : "test-model",
                provider: provider, in: window
            )
            let sessionId = UUID().uuidString
            await backend.enqueueScript([
                .systemInit(sessionId: sessionId),
                .assistantText("Hello from the agent"),
                .result(sessionId: sessionId)
            ], forCwd: cwd)

            let streamId = await appState.sendPrompt("Hello", includeIDEMCP: false, in: window)
            let completion = await appState.awaitStreamCompletion(streamId: try XCTUnwrap(streamId), timeout: 10)
            XCTAssertNotNil(completion, "No completion for \(provider)")
            XCTAssertNil(completion?.error)
            XCTAssertEqual(window.currentSessionId, sessionId)
            XCTAssertEqual(window.generalRoute, .chat)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cwd))
            XCTAssertTrue(appState.allSessionSummaries.contains { $0.id == sessionId && $0.projectId == Project.globalChatID })
            XCTAssertTrue(appState.messages(in: window).contains { $0.content.contains("Hello from the agent") })

            let followup = await appState.sendPrompt("Continue", includeIDEMCP: false, in: window)
            let resumed = await appState.awaitStreamCompletion(streamId: try XCTUnwrap(followup), timeout: 10)
            XCTAssertNotNil(resumed)
            let requests = await backend.receivedRequests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.last?.cwd, cwd)
            XCTAssertEqual(requests.last?.sessionId, sessionId)
        }
    }

    func testGlobalChatHistoryResumesAcrossProjectSwitch() async throws {
        let project = makeProject("Repository")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        let session = ChatSession(
            id: UUID().uuidString,
            projectId: Project.globalChatID,
            title: "Global conversation",
            messages: [ChatMessage(role: .user, content: "Hello")],
            agentProvider: .codex,
            model: "gpt-5.4",
            origin: .codexAppServer
        )
        appState.allSessionSummaries = [session.summary]
        await persistence.stubFullSession(session)

        appState.selectSession(id: session.id, in: window)
        for _ in 0..<100 where window.currentSessionId != session.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.currentSessionId, session.id)
        XCTAssertEqual(window.generalRoute, .chat)
        XCTAssertEqual(window.selectedProject?.id, Project.globalChatID)
        XCTAssertEqual(appState.messages(in: window).map(\.content), ["Hello"])
        XCTAssertEqual(appState.effectiveModelSelection(in: window).provider, .codex)

        window.generalRoute = .tasks
        appState.selectSession(id: session.id, in: window)
        XCTAssertEqual(window.generalRoute, .chat)
    }

    func testProjectHistoryOpensInsideChatTabWithOriginalContext() async throws {
        let project = makeProject("Repository")
        appState.projects = [project]
        appState.openGlobalChat(in: window)
        let session = ChatSession(
            id: UUID().uuidString, projectId: project.id, title: "Repository conversation",
            messages: [ChatMessage(role: .user, content: "Saved project message")],
            agentProvider: .codex, model: "test-model", origin: .codexAppServer
        )
        appState.allSessionSummaries = [session.summary]
        await persistence.stubFullSession(session)

        appState.selectSession(id: session.id, inChatTab: true, in: window)
        for _ in 0..<100 where window.currentSessionId != session.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.currentSessionId, session.id)
        XCTAssertEqual(window.generalRoute, .chat)
        XCTAssertEqual(window.selectedProject?.path, project.path)
        XCTAssertEqual(appState.messages(in: window).map(\.content), ["Saved project message"])
        XCTAssertEqual(appState.effectiveModelSelection(in: window).provider, .codex)

        // Re-selecting the current row must keep history visible too.
        appState.selectSession(id: session.id, inChatTab: true, in: window)
        XCTAssertEqual(window.generalRoute, .chat)

        // The regular sidebar still opens the project's chat surface.
        appState.selectSession(id: session.id, in: window)
        XCTAssertNil(window.generalRoute)
    }

    func testChatTabSelectsAnotherSessionInTheSameProject() {
        let project = makeProject("Repository")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        window.generalRoute = .chat
        let session = ChatSession(
            id: UUID().uuidString, projectId: project.id, title: "Saved chat",
            messages: [ChatMessage(role: .user, content: "Earlier message")]
        )
        appState.allSessionSummaries = [session.summary]
        var state = SessionStreamState()
        state.messages = session.messages
        appState.sessionStates[session.id] = state

        appState.selectSession(id: session.id, inChatTab: true, in: window)

        XCTAssertEqual(window.currentSessionId, session.id)
        XCTAssertEqual(window.generalRoute, .chat)
        XCTAssertEqual(appState.messages(in: window).map(\.content), ["Earlier message"])
    }

    func testNewChatFromProjectHistoryUsesGlobalContextAndPreservesDraft() {
        let project = makeProject("Repository")
        appState.projects = [project]
        appState.selectProject(project, in: window)
        window.generalRoute = .chat
        window.inputText = "Repository draft"

        appState.startNewGlobalChat(in: window)

        XCTAssertEqual(window.generalRoute, .chat)
        XCTAssertEqual(window.selectedProject?.id, Project.globalChatID)
        XCTAssertNil(window.currentSessionId)
        XCTAssertTrue(window.inputText.isEmpty)
        appState.selectProject(project, in: window)
        XCTAssertEqual(window.inputText, "Repository draft")
    }

    func testGlobalChatPersistsAndSurvivesStartupMaintenance() async {
        appState.autoArchiveEnabled = false
        appState.autoDeleteEnabled = false
        let sessionId = UUID().uuidString
        var state = SessionStreamState()
        state.agentProvider = .codex
        state.messages = [ChatMessage(role: .user, content: "Global message")]
        appState.sessionStates[sessionId] = state

        await appState.saveSession(sessionId: sessionId, projectId: Project.globalChatID, messages: state.messages)
        let saved = await persistence.savedSessions().last?.session
        XCTAssertEqual(saved?.projectId, Project.globalChatID)
        XCTAssertEqual(saved?.messages.first?.content, "Global message")
        XCTAssertTrue(appState.projects.isEmpty)

        await appState.runStartupStoreMaintenance()
        XCTAssertNotNil(appState.threadStore.fetch(id: sessionId))
        XCTAssertTrue(appState.allSessionSummaries.contains { $0.id == sessionId })
    }

    func testDeletingGlobalChatUsesItsWorkingDirectory() async {
        let session = ChatSession(id: UUID().uuidString, projectId: Project.globalChatID, title: "Chat", messages: [])
        appState.allSessionSummaries = [session.summary]
        await appState.deleteSession(session, in: window)
        let deletion = await persistence.deletedSessionRecords().last
        XCTAssertEqual(deletion?.cwd, appState.globalChatProject.path)
        XCTAssertFalse(appState.allSessionSummaries.contains { $0.id == session.id })
    }

    // MARK: - Retained chats and search

    func testDeletingProjectPreservesGlobalChatAndTranscript() async {
        let project = makeProject("Removed")
        let session = ChatSession(id: "global-chat", projectId: project.id, messages: [
            ChatMessage(role: .user, content: "Keep this conversation")
        ], origin: .codexAppServer)
        appState.projects = [project]
        appState.allSessionSummaries = [session.summary]
        appState.threadStore.upsert(session.summary)

        await appState.deleteProject(project, in: window)

        XCTAssertTrue(appState.projects.isEmpty)
        XCTAssertEqual(appState.allSessionSummaries.map(\.id), [session.id])
        XCTAssertNotNil(appState.threadStore.fetch(id: session.id))
        XCTAssertEqual(appState.sessionProject(id: project.id)?.path, project.path)
        let reloadedStore = ThreadStore(container: appState.threadStore.container)
        XCTAssertEqual(reloadedStore.retainedProject(id: project.id)?.name, project.name)
        let deletions = await persistence.deletedSessionRecords()
        XCTAssertTrue(deletions.isEmpty)
    }

    func testGlobalSearchRetainsAndOpensChatAfterProjectRemoval() async throws {
        let project = makeProject("Removed search project")
        let session = ChatSession(id: "retained-search-chat", projectId: project.id, messages: [
            ChatMessage(role: .user, content: "Find this conversation")
        ], origin: .codexAppServer)
        appState.projects = [project]
        appState.allSessionSummaries = [session.summary]
        appState.threadStore.upsert(session.summary)
        await persistence.stubFullSession(session)
        let hit = ThreadSearchService.Hit(
            threadId: session.id, projectId: project.id, score: 0.9,
            snippet: "Find this conversation", chunkIndex: 0
        )
        let results = [ThreadSearchService.Group(projectId: project.id, hits: [hit])]

        await appState.deleteProject(project, in: window)
        await appState.runStartupStoreMaintenance()

        XCTAssertTrue(appState.projects.isEmpty)
        XCTAssertFalse(appState.sessionProjects.contains { $0.id == project.id })
        XCTAssertEqual(appState.globalSearchGroups(results, excluding: nil), results)
        XCTAssertEqual(appState.sessionProject(id: project.id)?.name, project.name)

        appState.selectSession(id: hit.threadId, in: window)
        for _ in 0..<100 where window.currentSessionId != session.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.currentSessionId, session.id)
        XCTAssertEqual(window.selectedProject?.path, project.path)
        XCTAssertEqual(appState.messages(in: window).map(\.content), ["Find this conversation"])
        XCTAssertTrue(appState.projects.isEmpty)
    }

    func testGlobalSearchFiltersBySessionIdentityAndPreservesRanking() {
        let project = makeProject("Registered")
        let removedProjectId = UUID()
        appState.projects = [project]
        func hit(_ id: String, _ projectId: UUID, _ score: Float) -> ThreadSearchService.Hit {
            .init(threadId: id, projectId: projectId, score: score, snippet: id, chunkIndex: 0)
        }
        let retained = hit("retained", removedProjectId, 0.9)
        let current = hit("current", removedProjectId, 0.8)
        let global = hit("global", Project.globalChatID, 0.7)
        let registered = hit("registered", project.id, 0.6)
        let other = hit("other", project.id, 0.5)
        let stale = hit("deleted", UUID(), 0.4)
        appState.allSessionSummaries = [retained, current, global, registered, other].map {
            ChatSession(id: $0.threadId, projectId: $0.projectId, messages: []).summary
        }
        let results = [
            ThreadSearchService.Group(projectId: removedProjectId, hits: [retained, current]),
            .init(projectId: Project.globalChatID, hits: [global]),
            .init(projectId: project.id, hits: [registered, stale, other]),
            .init(projectId: stale.projectId, hits: [stale])
        ]

        XCTAssertEqual(appState.globalSearchGroups(results, excluding: current.threadId), [
            .init(projectId: removedProjectId, hits: [retained]),
            .init(projectId: Project.globalChatID, hits: [global]),
            .init(projectId: project.id, hits: [registered, other])
        ])
        XCTAssertEqual(appState.globalSearchGroups(results, excluding: nil).first?.hits, [retained, current])
        XCTAssertTrue(appState.globalSearchGroups([
            .init(projectId: removedProjectId, hits: [current])
        ], excluding: current.threadId).isEmpty)
    }

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())", gitHubRepo: nil)
    }

}
