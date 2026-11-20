import XCTest
import RxCodeCore
@testable import RxCode

extension AppStateTests {
    // MARK: - Project and session persistence

    func testAddProjectPersistsNewProjectAndSkipsDuplicatePath() async {
        await appState.addProject(name: "A", path: "/tmp/a", gitHubRepo: nil)
        await appState.addProject(name: "Duplicate", path: "/tmp/a", gitHubRepo: nil)

        XCTAssertEqual(appState.projects.map(\.name), ["A"])
        let saveCount = await persistence.savedProjectsSnapshots().count
        XCTAssertEqual(saveCount, 1)
    }

    func testAddingProjectFromFolderKeepsProjectsPageOpen() async {
        let currentProject = makeProject("Current")
        appState.projects = [currentProject]
        window.selectedProject = currentProject
        window.taskDetailProjectId = currentProject.id
        window.generalRoute = .tasks

        await appState.addProjectFromFolder(URL(fileURLWithPath: "/tmp/new-dashboard-project"), in: window)

        XCTAssertEqual(appState.projects.map(\.name), ["Current", "new-dashboard-project"])
        XCTAssertEqual(window.generalRoute, .tasks)
        XCTAssertEqual(window.taskDetailProjectId, currentProject.id)
        XCTAssertEqual(window.selectedProject?.id, currentProject.id)
        XCTAssertNil(window.currentSessionId)
    }

    func testAddingProjectFromChatSelectsNewProject() async {
        let currentProject = makeProject("Current")
        appState.projects = [currentProject]
        window.selectedProject = currentProject
        window.generalRoute = nil

        await appState.addProjectFromFolder(URL(fileURLWithPath: "/tmp/new-chat-project"), in: window)

        XCTAssertEqual(window.selectedProject?.name, "new-chat-project")
        XCTAssertNil(window.generalRoute)
    }

    func testSaveSessionSkipsEmptyMessages() async {
        await appState.saveSession(sessionId: "empty", projectId: UUID(), messages: [])

        let savedSessions = await persistence.savedSessions()
        XCTAssertTrue(savedSessions.isEmpty)
        XCTAssertTrue(appState.allSessionSummaries.isEmpty)
    }

    func testDeleteGenerationPreservesOtherTurnsAndPersistsEmptyTranscript() async throws {
        let project = makeProject("Studio")
        let first = ChatMessage(role: .user, content: "First image")
        let second = ChatMessage(role: .user, content: "Second image")
        let reply = ChatMessage(role: .assistant, content: "Generation failed")
        let session = ChatSession(id: "studio-delete", projectId: project.id,
                                  messages: [first, ChatMessage(role: .assistant, content: "First result"), second, reply],
                                  agentProvider: .localAgent, origin: .legacyRxCode)
        appState.projects = [project]
        appState.allSessionSummaries = [session.summary]
        var state = SessionStreamState()
        state.agentProvider = .localAgent
        state.messages = session.messages
        appState.sessionStates[session.id] = state
        await persistence.stubFullSession(session)

        try await appState.deleteGeneration(sessionID: session.id, messageID: first.id)
        XCTAssertEqual(appState.sessionStates[session.id]?.messages.map(\.id), [second.id, reply.id])
        let firstSave = await persistence.savedSessions().last?.session
        XCTAssertEqual(firstSave?.messages.map(\.id), [second.id, reply.id])

        try await appState.deleteGeneration(sessionID: session.id, messageID: second.id)
        let finalSave = await persistence.savedSessions().last?.session
        XCTAssertEqual(finalSave?.messages.count, 0)
        XCTAssertEqual(appState.sessionStates[session.id]?.messages.count, 0)
    }

    func testDeleteGenerationRejectsStreamingThread() async {
        var state = SessionStreamState()
        state.agentProvider = .localAgent
        state.isStreaming = true
        let prompt = ChatMessage(role: .user, content: "Rendering")
        state.messages = [prompt]
        appState.sessionStates["rendering"] = state
        do {
            try await appState.deleteGeneration(sessionID: "rendering", messageID: prompt.id)
            XCTFail("Deletion must not mutate a streaming thread")
        } catch {}
        XCTAssertEqual(appState.sessionStates["rendering"]?.messages.map(\.id), [prompt.id])
        let saves = await persistence.savedSessions()
        XCTAssertTrue(saves.isEmpty)
    }

    func testSaveSessionBuildsSessionFromStateAndUpdatesSummariesAndProject() async {
        let project = makeProject("A")
        appState.projects = [project]

        var state = SessionStreamState()
        state.agentProvider = .codex
        state.model = "gpt-5.4"
        state.effort = "high"
        state.permissionMode = .auto
        appState.sessionStates["session"] = state

        let user = ChatMessage(role: .user, content: "Question", timestamp: Date(timeIntervalSince1970: 1))
        let assistant = ChatMessage(role: .assistant, content: "Answer", timestamp: Date(timeIntervalSince1970: 2))

        await appState.saveSession(sessionId: "session", projectId: project.id, messages: [user, assistant])

        let saved = await persistence.savedSessions().last?.session
        XCTAssertEqual(saved?.id, "session")
        XCTAssertEqual(saved?.title, ChatSession.defaultTitle)
        XCTAssertEqual(saved?.agentProvider, .codex)
        XCTAssertEqual(saved?.model, "gpt-5.4")
        XCTAssertEqual(saved?.effort, "high")
        XCTAssertEqual(saved?.permissionMode, .auto)
        XCTAssertEqual(saved?.updatedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(appState.allSessionSummaries.map(\.id), ["session"])
        XCTAssertEqual(appState.projects.first?.lastSessionId, "session")
        let savedProjectSessionId = await persistence.savedProjectsSnapshots().last?.first?.lastSessionId
        XCTAssertEqual(savedProjectSessionId, "session")
    }

    func testSaveSessionPreservesExistingSummaryMetadata() async {
        let project = makeProject("A")
        let archivedAt = Date(timeIntervalSince1970: 99)
        appState.projects = [project]
        appState.allSessionSummaries = [
            ChatSession.Summary(
                id: "session",
                projectId: project.id,
                title: "Manual Title",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                isPinned: true,
                agentProvider: .claudeCode,
                model: "opus",
                effort: "medium",
                permissionMode: .acceptEdits,
                origin: .legacyRxCode,
                worktreePath: "/tmp/worktree",
                worktreeBranch: "feature",
                isArchived: true,
                archivedAt: archivedAt
            ),
        ]

        await appState.saveSession(
            sessionId: "session",
            projectId: project.id,
            messages: [ChatMessage(role: .assistant, content: "Answer")]
        )

        let saved = await persistence.savedSessions().last?.session
        XCTAssertEqual(saved?.title, "Manual Title")
        XCTAssertEqual(saved?.isPinned, true)
        XCTAssertEqual(saved?.agentProvider, .claudeCode)
        XCTAssertEqual(saved?.model, "opus")
        XCTAssertEqual(saved?.effort, "medium")
        XCTAssertEqual(saved?.permissionMode, .acceptEdits)
        XCTAssertEqual(saved?.origin, .legacyRxCode)
        XCTAssertEqual(saved?.worktreePath, "/tmp/worktree")
        XCTAssertEqual(saved?.worktreeBranch, "feature")
        XCTAssertEqual(saved?.isArchived, true)
        XCTAssertEqual(saved?.archivedAt, archivedAt)
    }

    func testSaveSessionDoesNotUpdateSummaryWhileStreaming() async {
        let project = makeProject("A")
        appState.projects = [project]
        var state = SessionStreamState()
        state.isStreaming = true
        appState.sessionStates["streaming"] = state

        await appState.saveSession(
            sessionId: "streaming",
            projectId: project.id,
            messages: [ChatMessage(role: .assistant, content: "Still going")]
        )

        let savedCount = await persistence.savedSessions().count
        XCTAssertEqual(savedCount, 1)
        XCTAssertTrue(appState.allSessionSummaries.isEmpty)
    }

    func testRenameProjectTrimsNameAndPersistsProjects() async {
        let project = makeProject("Old")
        appState.projects = [project]

        await appState.renameProject(project, to: "  New Name  ")

        XCTAssertEqual(appState.projects.first?.name, "New Name")
        let savedProjectName = await persistence.savedProjectsSnapshots().last?.first?.name
        XCTAssertEqual(savedProjectName, "New Name")
    }

    func testRenameProjectIgnoresBlankName() async {
        let project = makeProject("Old")
        appState.projects = [project]

        await appState.renameProject(project, to: " \n ")

        XCTAssertEqual(appState.projects.first?.name, "Old")
        let savedProjects = await persistence.savedProjectsSnapshots()
        XCTAssertTrue(savedProjects.isEmpty)
    }

    func testProjectPromptPersistsLatestEdit() async {
        let project = makeProject("Prompt")
        appState.projects = [project]

        appState.setProjectPrompt("First draft", for: project.id)
        appState.setProjectPrompt("Final instructions", for: project.id)
        await appState.projectPromptSaveTask?.value

        let savedPrompt = await persistence.savedProjectsSnapshots().last?.first?.customPrompt
        XCTAssertEqual(savedPrompt, "Final instructions")
    }

    // MARK: - Notifications and settings

    func testProjectWindowRegistrationIsReferenceCounted() {
        let projectId = UUID()

        appState.registerOpenProjectWindow(projectId)
        appState.registerOpenProjectWindow(projectId)
        XCTAssertTrue(appState.hasOpenProjectWindow(for: projectId))

        appState.unregisterOpenProjectWindow(projectId)
        XCTAssertTrue(appState.hasOpenProjectWindow(for: projectId))

        appState.unregisterOpenProjectWindow(projectId)
        XCTAssertFalse(appState.hasOpenProjectWindow(for: projectId))
    }

    func testHandleNotificationTapQueuesSessionForOpenProjectWindow() {
        let projectId = UUID()
        appState.registerOpenProjectWindow(projectId)

        appState.handleNotificationTap(projectId: projectId, sessionId: "session", mainWindow: window)

        XCTAssertEqual(appState.pendingNotificationSession[projectId], "session")
        XCTAssertNil(window.currentSessionId)
    }

    func testHandleNotificationTapSelectsSessionWhenMainWindowAlreadyShowsProject() {
        let project = makeProject("A")
        window.selectedProject = project

        appState.handleNotificationTap(projectId: project.id, sessionId: "session", mainWindow: window)

        XCTAssertEqual(window.currentSessionId, "session")
    }
}
