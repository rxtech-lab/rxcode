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

    // MARK: - Project and session persistence

    func testAddProjectPersistsNewProjectAndSkipsDuplicatePath() async {
        await appState.addProject(name: "A", path: "/tmp/a", gitHubRepo: nil)
        await appState.addProject(name: "Duplicate", path: "/tmp/a", gitHubRepo: nil)

        XCTAssertEqual(appState.projects.map(\.name), ["A"])
        let saveCount = await persistence.savedProjectsSnapshots().count
        XCTAssertEqual(saveCount, 1)
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

private actor MockAppStatePersistence: AppStatePersistenceService {
    private var projectSnapshots: [[Project]] = []
    private var sessionSaves: [(session: ChatSession, persistTitle: Bool)] = []
    private var deletedSessions: [(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?)] = []
    private var runProfiles: [UUID: [RunProfile]] = [:]
    private var hookProfiles: [UUID: [HookProfile]] = [:]
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
