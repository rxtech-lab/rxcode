import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class AppStateTests: XCTestCase {

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

    // MARK: - Session counters and accessors

    func testInProgressSessionCountCountsOnlyStreamingStates() {
        appState.sessionStates = [
            "idle": streamState(isStreaming: false),
            "live-a": streamState(isStreaming: true),
            "live-b": streamState(isStreaming: true),
        ]

        XCTAssertEqual(appState.inProgressSessionCount, 2)
    }

    func testUncheckedFinishedSessionCountCountsOnlyUncheckedCompletions() {
        var seen = SessionStreamState()
        seen.hasUncheckedCompletion = false
        var unseen = SessionStreamState()
        unseen.hasUncheckedCompletion = true
        appState.sessionStates = ["seen": seen, "unseen": unseen]

        XCTAssertEqual(appState.uncheckedFinishedSessionCount, 1)
    }

    func testWindowScopedAccessorsUseCurrentSessionState() {
        let sessionId = "thread-1"
        window.currentSessionId = sessionId

        var state = SessionStreamState()
        state.messages = [
            ChatMessage(role: .user, content: "Question"),
            ChatMessage(role: .assistant, content: "Answer"),
        ]
        state.isStreaming = true
        state.isThinking = true
        state.streamingStartDate = Date(timeIntervalSince1970: 42)
        state.activeModelName = "Actual Model"
        state.lastTurnContextUsedPercentage = 72.5
        state.costUsd = 1.25
        state.turns = 3
        state.inputTokens = 100
        state.outputTokens = 200
        state.cacheCreationTokens = 30
        state.cacheReadTokens = 40
        state.durationMs = 5_000
        appState.sessionStates[sessionId] = state

        XCTAssertEqual(appState.messages(in: window).map(\.content), ["Question", "Answer"])
        XCTAssertTrue(appState.isStreaming(in: window))
        XCTAssertTrue(appState.isThinking(in: window))
        XCTAssertEqual(appState.streamingStartDate(in: window), Date(timeIntervalSince1970: 42))
        XCTAssertEqual(appState.activeModelName(in: window), "Actual Model")
        XCTAssertEqual(appState.lastTurnContextUsedPercentage(in: window), 72.5)
        XCTAssertEqual(appState.sessionCostUsd(in: window), 1.25)
        XCTAssertEqual(appState.sessionTurns(in: window), 3)
        XCTAssertEqual(appState.sessionInputTokens(in: window), 100)
        XCTAssertEqual(appState.sessionOutputTokens(in: window), 200)
        XCTAssertEqual(appState.sessionCacheCreationTokens(in: window), 30)
        XCTAssertEqual(appState.sessionCacheReadTokens(in: window), 40)
        XCTAssertEqual(appState.sessionDurationMs(in: window), 5_000)
    }

    func testStreamStateFallsBackToNewSessionKey() {
        let project = makeProject("A")
        window.selectedProject = project

        var state = SessionStreamState()
        state.messages = [ChatMessage(role: .user, content: "Draft thread")]
        appState.sessionStates[window.newSessionKey] = state

        XCTAssertEqual(appState.messages(in: window).map(\.content), ["Draft thread"])
    }

    // MARK: - Task board chat activity

    func testRecentStoriesUsesLatestChildActivityAndMatchesChildKeywords() {
        let projectId = UUID()
        let older = ProjectStory(projectId: projectId, title: "Older", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = ProjectStory(projectId: projectId, title: "Newer", updatedAt: Date(timeIntervalSince1970: 20))
        let child = ProjectTask(
            projectId: projectId,
            storyId: older.id,
            title: "Find this child",
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        appState.taskBoards[projectId] = TaskBoard(stories: [newer, older], tasks: [child])

        XCTAssertEqual(appState.recentStories(for: projectId).map(\.id), [older.id, newer.id])
        XCTAssertEqual(appState.recentStories(for: projectId, keyword: "Find this").map(\.id), [older.id])
    }

    func testIsAgentRunningIsFalseWithoutALinkedThread() {
        let task = ProjectTask(projectId: UUID(), title: "No thread", sessionKey: nil)
        appState.sessionStates = ["sess-1": streamState(isStreaming: true)]

        XCTAssertFalse(appState.isAgentRunning(for: task))
    }

    func testIsAgentRunningFollowsTheLinkedThreadsStreamingState() {
        let task = ProjectTask(projectId: UUID(), title: "Linked", sessionKey: "sess-1")

        XCTAssertFalse(appState.isAgentRunning(for: task), "no state yet means nothing is streaming")

        appState.sessionStates = ["sess-1": streamState(isStreaming: true)]
        XCTAssertTrue(appState.isAgentRunning(for: task))

        appState.sessionStates = ["sess-1": streamState(isStreaming: false)]
        XCTAssertFalse(appState.isAgentRunning(for: task))
    }

    func testIsAgentRunningResolvesARenamedSessionId() {
        // A task dispatched this launch is still linked to the `pending-…` key
        // the stream opened under; the CLI rename lives in the redirect table.
        let task = ProjectTask(projectId: UUID(), title: "Pending link", sessionKey: "pending-1")
        appState.sessionIdRedirect = ["pending-1": "real-1"]
        appState.sessionStates = ["real-1": streamState(isStreaming: true)]

        XCTAssertTrue(appState.isAgentRunning(for: task))
    }

    func testLinkedTaskFindsRenamedThreadOnlyInItsProject() {
        let project = makeProject("Chat")
        let otherProject = makeProject("Other")
        let task = ProjectTask(projectId: project.id, title: "Linked", sessionKey: "pending-1")
        let sourceTask = ProjectTask(projectId: project.id, title: "From chat", sourceSessionKey: "source-1")
        appState.setTaskBoard(TaskBoard(tasks: [task, sourceTask]), for: project.id)
        appState.sessionIdRedirect = ["pending-1": "real-1"]

        XCTAssertEqual(appState.linkedTask(forSessionId: "real-1", projectId: project.id)?.id, task.id)
        XCTAssertEqual(appState.linkedTask(forSessionId: "source-1", projectId: project.id)?.id, sourceTask.id)
        XCTAssertFalse(sourceTask.isDescriptionLocked)
        XCTAssertNil(appState.linkedTask(forSessionId: "real-1", projectId: otherProject.id))
        XCTAssertNil(appState.linkedTask(forSessionId: "unlinked", projectId: project.id))
    }

    func testIsAgentRunningForStoryIsTrueWhileAnyChildTaskStreams() {
        let project = makeProject("Board")
        let story = ProjectStory(projectId: project.id, title: "Projects Dashboard")
        let idle = ProjectTask(projectId: project.id, storyId: story.id, title: "Idle", sessionKey: "sess-idle")
        let live = ProjectTask(projectId: project.id, storyId: story.id, title: "Live", sessionKey: "sess-live")
        let other = ProjectTask(projectId: project.id, title: "Unparented", sessionKey: "sess-other")
        let board = TaskBoard(stories: [story], tasks: [idle, live, other])

        appState.sessionStates = [
            "sess-idle": streamState(isStreaming: false),
            "sess-live": streamState(isStreaming: true),
        ]
        XCTAssertTrue(appState.isAgentRunning(forStory: story, in: board))

        appState.sessionStates = [
            "sess-idle": streamState(isStreaming: false),
            "sess-live": streamState(isStreaming: false),
            // A task outside the story must not light the story card up.
            "sess-other": streamState(isStreaming: true),
        ]
        XCTAssertFalse(appState.isAgentRunning(forStory: story, in: board))
    }

    // MARK: - Drafts and queues

    func testDraftKeyIsProjectScopedBeforeSessionExists() {
        let project = makeProject("Project")
        window.selectedProject = project

        XCTAssertEqual(appState.draftKey(for: window), "new:\(project.id.uuidString)")
    }

    func testSaveDraftStoresNonEmptyTextAndRemovesBlankText() {
        window.currentSessionId = "session"
        window.inputText = "  keep me  "

        appState.saveDraft(in: window)
        XCTAssertEqual(window.draftTexts["session"], "  keep me  ")

        window.inputText = " \n\t "
        appState.saveDraft(in: window)
        XCTAssertNil(window.draftTexts["session"])
    }

    func testSaveQueueStoresAndRemovesCurrentQueue() {
        window.currentSessionId = "session"
        window.messageQueue = [QueuedMessage(text: "queued", attachments: [])]

        appState.saveQueue(in: window)
        XCTAssertEqual(window.draftQueues["session"]?.map(\.text), ["queued"])

        window.messageQueue = []
        appState.saveQueue(in: window)
        XCTAssertNil(window.draftQueues["session"])
    }

    func testRenameDraftStateMovesTextAndMergesQueues() {
        let moving = QueuedMessage(text: "moving", attachments: [])
        let existing = QueuedMessage(text: "existing", attachments: [])
        window.draftTexts["old"] = "draft"
        window.draftQueues["old"] = [moving]
        window.draftQueues["new"] = [existing]

        appState.renameDraftState(from: "old", to: "new", in: window)

        XCTAssertNil(window.draftTexts["old"])
        XCTAssertEqual(window.draftTexts["new"], "draft")
        XCTAssertNil(window.draftQueues["old"])
        XCTAssertEqual(window.draftQueues["new"]?.map(\.text), ["existing", "moving"])
    }

    func testResetToNewChatRestoresProjectScopedDraftAndQueue() {
        let project = makeProject("A")
        window.selectedProject = project
        window.currentSessionId = "old"
        let draftKey = "new:\(project.id.uuidString)"
        let stateKey = window.newSessionKey
        window.draftTexts[draftKey] = "draft"
        window.draftQueues[draftKey] = [QueuedMessage(text: "queued", attachments: [])]
        appState.sessionStates[stateKey] = streamState(isStreaming: false)

        appState.resetToNewChat(in: window)

        XCTAssertNil(window.currentSessionId)
        XCTAssertNil(window.sessionModel)
        XCTAssertFalse(window.sessionPlanMode)
        XCTAssertEqual(window.inputText, "draft")
        XCTAssertEqual(window.messageQueue.map(\.text), ["queued"])
        XCTAssertNil(appState.sessionStates[stateKey])
        XCTAssertTrue(window.requestInputFocus)
    }

    // MARK: - Message cleanup and titles

    func testCleanLoadedMessagesDropsEmptyAssistantAndStopsStreaming() {
        let cleaned = appState.cleanLoadedMessages([
            ChatMessage(role: .assistant, content: ""),
            ChatMessage(role: .assistant, content: "done", isStreaming: true),
            ChatMessage(role: .user, content: ""),
        ])

        XCTAssertEqual(cleaned.count, 2)
        XCTAssertEqual(cleaned.map(\.role), [.assistant, .user])
        XCTAssertEqual(cleaned.first?.content, "done")
        XCTAssertFalse(cleaned[0].isStreaming)
    }

    func testLastResponseDatePrefersLastAssistantMessage() {
        let userDate = Date(timeIntervalSince1970: 10)
        let firstAssistantDate = Date(timeIntervalSince1970: 20)
        let lastAssistantDate = Date(timeIntervalSince1970: 30)

        let result = appState.lastResponseDate(from: [
            ChatMessage(role: .user, content: "q", timestamp: userDate),
            ChatMessage(role: .assistant, content: "a1", timestamp: firstAssistantDate),
            ChatMessage(role: .user, content: "follow up", timestamp: Date(timeIntervalSince1970: 40)),
            ChatMessage(role: .assistant, content: "a2", timestamp: lastAssistantDate),
        ])

        XCTAssertEqual(result, lastAssistantDate)
    }

    func testAutoGeneratedTitleDetectionMatchesKnownPlaceholders() {
        XCTAssertTrue(appState.isAutoGeneratedTitle(ChatSession.defaultTitle, firstUserMessage: "Build this"))
        XCTAssertTrue(appState.isAutoGeneratedTitle("Build this", firstUserMessage: "Build this"))
        XCTAssertTrue(appState.isAutoGeneratedTitle("New session", firstUserMessage: "Build this"))
        XCTAssertTrue(appState.isAutoGeneratedTitle("", firstUserMessage: "Build this"))
        XCTAssertFalse(appState.isAutoGeneratedTitle("User Rename", firstUserMessage: "Build this"))
    }

    func testResolveCurrentSessionIdFollowsRedirectChainAndStopsAtCycle() {
        appState.sessionIdRedirect = [
            "pending": "real",
            "real": "compacted",
            "cycle-a": "cycle-b",
            "cycle-b": "cycle-a",
        ]

        XCTAssertEqual(appState.resolveCurrentSessionId("pending"), "compacted")
        XCTAssertEqual(appState.resolveCurrentSessionId("cycle-a"), "cycle-b")
    }

    // MARK: - Model state

    func testSetSessionModelUpdatesWindowStateSessionStateAndProjectDefault() async {
        let project = makeProject("A")
        appState.projects = [project]
        window.selectedProject = project
        window.currentSessionId = "session"

        appState.setSessionModel("gpt-5.4", provider: .codex, in: window)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(window.sessionAgentProvider, .codex)
        XCTAssertEqual(window.sessionModel, "gpt-5.4")
        XCTAssertEqual(appState.sessionStates["session"]?.agentProvider, .codex)
        XCTAssertEqual(appState.sessionStates["session"]?.model, "gpt-5.4")
        XCTAssertNil(appState.sessionStates["session"]?.activeModelName)
        XCTAssertEqual(appState.projects.first?.lastAgentProvider, .codex)
        XCTAssertEqual(appState.projects.first?.lastModel, "gpt-5.4")
        let savedProjectModel = await persistence.savedProjectsSnapshots().last?.first?.lastModel
        XCTAssertEqual(savedProjectModel, "gpt-5.4")
    }

    func testSetSessionEffortPermissionAndPlanModeUpdateCurrentSessionState() {
        window.currentSessionId = "session"

        appState.setSessionEffort("high", in: window)
        appState.setSessionPermissionMode(.auto, in: window)
        appState.toggleSessionPlanMode(in: window)
        appState.toggleSessionPlanMode(in: window)

        XCTAssertEqual(window.sessionEffort, "high")
        XCTAssertEqual(window.sessionPermissionMode, .auto)
        XCTAssertFalse(window.sessionPlanMode)
        XCTAssertEqual(appState.sessionStates["session"]?.effort, "high")
        XCTAssertEqual(appState.sessionStates["session"]?.permissionMode, .auto)
        XCTAssertEqual(appState.sessionStates["session"]?.planMode, false)
    }

    func testDefaultModelSelectionPrefersValidProjectDefault() {
        let project = Project(
            name: "A",
            path: "/tmp/a",
            lastAgentProvider: .codex,
            lastModel: "gpt-5.4"
        )

        let selection = appState.defaultModelSelection(for: project)

        XCTAssertEqual(selection.provider, .codex)
        XCTAssertEqual(selection.model, "gpt-5.4")
    }

    func testDefaultModelSelectionFallsBackWhenProjectDefaultUnavailable() {
        appState.selectedAgentProvider = .claudeCode
        appState.selectedModel = "sonnet"
        let project = Project(
            name: "A",
            path: "/tmp/a",
            lastAgentProvider: .codex,
            lastModel: "not-installed"
        )

        let selection = appState.defaultModelSelection(for: project)

        XCTAssertEqual(selection.provider, .claudeCode)
        XCTAssertEqual(selection.model, "sonnet")
    }

    func testEffectiveModelSelectionHonorsProviderOnlyOverride() {
        appState.selectedAgentProvider = .claudeCode
        appState.selectedModel = "sonnet"
        window.sessionAgentProvider = .codex

        let selection = appState.effectiveModelSelection(in: window)

        XCTAssertEqual(selection.provider, .codex)
        XCTAssertEqual(selection.model, AppState.fallbackCodexModels.first)
    }

    func testACPModelDisplayResolvesClientAndModelOptionNames() {
        appState.acpClients = [
            ACPClientSpec(
                id: "client",
                displayName: "Gemini CLI",
                launch: .custom(command: "gemini", args: [], env: [:]),
                modelOptions: [
                    ACPModelOption(value: "pro", name: "Google/Gemini Pro"),
                ]
            ),
        ]

        XCTAssertEqual(AppState.splitACPModelKey("client::pro")?.clientId, "client")
        XCTAssertEqual(AppState.splitACPModelKey("client::pro")?.model, "pro")
        XCTAssertEqual(appState.acpSelectionParts(for: "client::pro")?.clientId, "client")
        XCTAssertEqual(appState.modelDisplayLabel("client::pro", provider: .acp), "Gemini CLI · Gemini Pro")
    }

    func testACPModelSectionsIncludeEnabledClientsAndSkipDisabledClients() {
        appState.acpClients = [
            ACPClientSpec(
                id: "enabled",
                displayName: "Enabled",
                enabled: true,
                launch: .custom(command: "enabled", args: [], env: [:]),
                models: ["model-a"]
            ),
            ACPClientSpec(
                id: "disabled",
                displayName: "Disabled",
                enabled: false,
                launch: .custom(command: "disabled", args: [], env: [:]),
                models: ["model-b"]
            ),
        ]

        let acpSections = appState.availableAgentModelSections().filter { $0.provider == .acp }

        XCTAssertEqual(acpSections.map(\.id), ["acp:enabled"])
        XCTAssertEqual(acpSections.first?.models.map(\.id), ["enabled::model-a"])
    }

    func testACPExactVersionUsesPackageInsteadOfCurrentRegistryBinary() async throws {
        let agent = try JSONDecoder().decode(ACPRegistryAgent.self, from: Data(#"""
        {
          "id": "example", "name": "Example", "version": "2.0.0", "description": "Example",
          "distribution": {
            "npx": {"package": "@example/agent@2.0.0"},
            "binary": {"darwin-aarch64": {"archive": "https://example.com/agent-2.0.0.zip", "cmd": "agent"}}
          }
        }
        """#.utf8))

        let launch = try await appState.resolveLaunch(for: agent, version: "1.2.3")
        guard case .npx(let package, _, _) = launch else {
            return XCTFail("Expected the exact package release")
        }
        XCTAssertEqual(package, "@example/agent@1.2.3")
    }

    func testACPBinaryOnlyClientRejectsUnavailableExactVersion() async throws {
        let agent = try JSONDecoder().decode(ACPRegistryAgent.self, from: Data(#"""
        {
          "id": "example", "name": "Example", "version": "2.0.0", "description": "Example",
          "distribution": {
            "binary": {"darwin-aarch64": {"archive": "https://example.com/agent-2.0.0.zip", "cmd": "agent"}}
          }
        }
        """#.utf8))

        do {
            _ = try await appState.resolveLaunch(for: agent, version: "1.2.3")
            XCTFail("Expected an unavailable version error")
        } catch ACPInstallError.historicalBinaryUnavailable(let version) {
            XCTAssertEqual(version, "1.2.3")
        }
    }

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

    func testMemoryMaxContextItemsClampsToSupportedRange() {
        appState.memoryMaxContextItems = 0
        XCTAssertEqual(appState.memoryMaxContextItems, 1)

        appState.memoryMaxContextItems = 99
        XCTAssertEqual(appState.memoryMaxContextItems, 12)

        appState.memoryMaxContextItems = 7
        XCTAssertEqual(appState.memoryMaxContextItems, 7)
    }

    // MARK: - Pull request content

    func testParsePullRequestContentNormalizesConventionalTitle() {
        let raw = """
        Fix: Enhance parallel API calls and improve startup warmup and Autopilot API handling.

        Updates the branch behavior.
        """

        let result = AppState.parsePullRequestContent(raw, branch: "context-menu")

        XCTAssertEqual(
            result.title,
            "fix: enhance parallel API calls and improve startup warmup and Autopilot API handling"
        )
        XCTAssertEqual(result.body, "Updates the branch behavior.")
    }

    func testParsePullRequestContentNormalizesScopedConventionalTitle() {
        let raw = """
        Title: Feat(Autopilot): Add docs search!

        Adds the docs search flow.
        """

        let result = AppState.parsePullRequestContent(raw, branch: "context-menu")

        XCTAssertEqual(result.title, "feat(autopilot): add docs search")
        XCTAssertEqual(result.body, "Adds the docs search flow.")
    }

    func testIsConventionalCommitTitleAcceptsValidTitles() {
        XCTAssertTrue(AppState.isConventionalCommitTitle("fix: correct the crash"))
        XCTAssertTrue(AppState.isConventionalCommitTitle("feat(autopilot): add docs search"))
        XCTAssertTrue(AppState.isConventionalCommitTitle("docs: update readme"))
        XCTAssertTrue(AppState.isConventionalCommitTitle("feat!: drop legacy api"))
        XCTAssertTrue(AppState.isConventionalCommitTitle("refactor(core)!: restructure store"))
    }

    func testIsConventionalCommitTitleRejectsInvalidTitles() {
        // Type not on the allowed list.
        XCTAssertFalse(AppState.isConventionalCommitTitle("feature: add docs search"))
        XCTAssertFalse(AppState.isConventionalCommitTitle("update: tweak things"))
        // No conventional prefix at all.
        XCTAssertFalse(AppState.isConventionalCommitTitle("Add a new docs search flow"))
        // Missing description after the colon.
        XCTAssertFalse(AppState.isConventionalCommitTitle("fix:"))
        XCTAssertFalse(AppState.isConventionalCommitTitle(""))
    }

    func testParsePullRequestContentTruncatesTitleToTwentyWords() {
        let raw = """
        feat: add one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty

        Body text.
        """

        let result = AppState.parsePullRequestContent(raw, branch: "context-menu")

        let wordCount = result.title.split(whereSeparator: { $0.isWhitespace }).count
        XCTAssertEqual(wordCount, AppState.maxPullRequestTitleWords)
        XCTAssertEqual(
            result.title,
            "feat: add one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen"
        )
        XCTAssertEqual(result.body, "Body text.")
    }

    func testParsePullRequestContentKeepsShortTitleUnchanged() {
        let raw = """
        fix: correct the crash on launch

        Body text.
        """

        let result = AppState.parsePullRequestContent(raw, branch: "context-menu")

        XCTAssertEqual(result.title, "fix: correct the crash on launch")
    }

    func testTruncatePullRequestTitleWordsStripsDanglingPunctuation() {
        // 21 words where the 20th word ends in a period; truncation must drop the
        // trailing punctuation left dangling at the cut.
        let title = "feat: add one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen. nineteen"

        let truncated = AppState.truncatePullRequestTitleWords(title)

        XCTAssertEqual(
            truncated,
            "feat: add one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen"
        )
        XCTAssertEqual(
            truncated.split(whereSeparator: { $0.isWhitespace }).count,
            AppState.maxPullRequestTitleWords
        )
    }

    // MARK: - Helpers

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())", gitHubRepo: nil)
    }

    private func streamState(isStreaming: Bool) -> SessionStreamState {
        var state = SessionStreamState()
        state.isStreaming = isStreaming
        return state
    }
}

@MainActor
final class ClaudeLoginTests: XCTestCase {
    func testInteractivePromptFallsBackBeforeProcessExits() async throws {
        let script = try loginScript("print -n 'Paste code here if prompted > '\nexec /bin/sleep 10")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let started = Date()

        do {
            try await makeAppState().claude.runLoginProcess(
                binary: script.path, timeout: .seconds(2),
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected an interactive login fallback")
        } catch ClaudeCodeServer.ClaudeError.interactiveLoginRequired {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        }
    }

    func testUnrecognizedPromptFallsBackOnTimeout() async throws {
        let script = try loginScript("print -n 'Waiting for authorization... '\nexec /bin/sleep 10")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let started = Date()

        do {
            try await makeAppState().claude.runLoginProcess(
                binary: script.path, timeout: .milliseconds(200),
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected a timed login fallback")
        } catch ClaudeCodeServer.ClaudeError.interactiveLoginRequired {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testCompletedBackgroundLoginSucceeds() async throws {
        let script = try loginScript("print 'Login complete'\nexit 0")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        try await makeAppState().claude.runLoginProcess(
            binary: script.path, timeout: .seconds(2),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func loginScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RxCode-ClaudeLoginTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("claude")
        try "#!/bin/zsh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func makeAppState() -> AppState {
        AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
    }
}

/// Shared by the app-level test target (also used by `TaskBoardHookTests`).
actor MockAppStatePersistence: AppStatePersistenceService {
    private var projectSnapshots: [[Project]] = []
    private var sessionSaves: [(session: ChatSession, persistTitle: Bool)] = []
    private var deletedSessions: [(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?)] = []
    private var runProfiles: [UUID: [RunProfile]] = [:]
    private var hookProfiles: [UUID: [HookProfile]] = [:]
    private var taskBoards: [UUID: TaskBoard] = [:]
    private var acpClients: [ACPClientSpec] = []
    private var fullSessions: [String: ChatSession] = [:]
    private var legacySessions: [String: ChatSession] = [:]

    func savedProjectsSnapshots() -> [[Project]] {
        projectSnapshots
    }

    func savedSessions() -> [(session: ChatSession, persistTitle: Bool)] {
        sessionSaves
    }

    func deletedSessionRecords() -> [(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?)] {
        deletedSessions
    }

    func stubFullSession(_ session: ChatSession) {
        fullSessions[session.id] = session
    }

    func stubLegacySession(_ session: ChatSession) {
        legacySessions[session.id] = session
    }

    func saveProjects(_ projects: [Project]) throws {
        projectSnapshots.append(projects)
    }

    func loadProjects() -> [Project] {
        projectSnapshots.last ?? []
    }

    func saveSession(_ session: ChatSession, persistTitle: Bool) async throws {
        sessionSaves.append((session, persistTitle))
    }

    func loadLegacySessions(for projectId: UUID) -> [ChatSession.Summary] {
        legacySessions.values
            .filter { $0.projectId == projectId }
            .map(\.summary)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadAllLegacySessionSummaries() -> [ChatSession.Summary] {
        legacySessions.values.map(\.summary).sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteSession(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?) async throws {
        deletedSessions.append((projectId, sessionId, origin, cwd))
    }

    func loadFullSession(summary: ChatSession.Summary, cwd: String) async -> ChatSession? {
        fullSessions[summary.id]
    }

    nonisolated func legacySessionURL(projectId: UUID, sessionId: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(projectId.uuidString)/\(sessionId).json")
    }

    nonisolated func loadLegacySessionSync(projectId: UUID, sessionId: String) -> ChatSession? {
        nil
    }

    func saveRunProfiles(_ profiles: [RunProfile], projectId: UUID) throws {
        runProfiles[projectId] = profiles
    }

    func loadRunProfiles(projectId: UUID) -> [RunProfile] {
        runProfiles[projectId] ?? []
    }

    func saveHookProfiles(_ profiles: [HookProfile], projectId: UUID) throws {
        hookProfiles[projectId] = profiles
    }

    func loadHookProfiles(projectId: UUID) -> [HookProfile] {
        hookProfiles[projectId] ?? []
    }

    func saveTaskBoard(_ board: TaskBoard, projectId: UUID) throws {
        taskBoards[projectId] = board
    }

    func loadTaskBoard(projectId: UUID) -> TaskBoard {
        taskBoards[projectId] ?? TaskBoard()
    }

    func deleteTaskBoard(projectId: UUID) throws {
        taskBoards.removeValue(forKey: projectId)
    }

    func saveACPClients(_ clients: [ACPClientSpec]) throws {
        acpClients = clients
    }

    func loadACPClients() -> [ACPClientSpec] {
        acpClients
    }

    nonisolated func acpRegistrySnapshotURL() -> URL {
        URL(fileURLWithPath: "/tmp/acp_registry.json")
    }


}
