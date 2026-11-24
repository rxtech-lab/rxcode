import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class CodingPlanTests: XCTestCase {
    let planner = AgentModel(provider: .codex, id: "planner", displayName: "Planner model")
    let host = AgentModel(provider: .claudeCode, id: "host", displayName: "Host model")
    let reviewer = AgentModel(provider: .acp, id: "test::review", displayName: "Review model")
    private(set) var state: AppState!
    private(set) var window: WindowState!
    private(set) var project: Project!
    private(set) var repo: URL!
    private(set) var persistence: MockAppStatePersistence!
    private let workspaceID = UUID().uuidString

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        project = Project(name: "Plan fixture", path: repo.path)
        persistence = MockAppStatePersistence()
        state = AppState(persistence: persistence, startBackgroundServices: false)
        state.workspaceDefaults = WorkspaceDefaults(workspaceID: workspaceID)
        state.threadStore = .inMemory()
        state.projects = [project]
        state.summarizationProvider = .openAI
        state.openAISummarizationModel = ""
        state.acpClients = [.init(id: "test", displayName: "Review client",
                                  launch: .binary(path: "/usr/bin/false", args: [], env: [:]), models: ["review"])]
        window = WindowState()
        window.selectedProject = project
    }

    override func tearDown() async throws {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("workspace.\(workspaceID).") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try FileManager.default.removeItem(at: repo)
    }

    func backend(_ provider: AgentProvider) -> MockAgentBackend {
        let mock = MockAgentBackend(provider: provider)
        state.agentBackendOverrides[provider] = mock
        return mock
    }

    func answer(_ text: String, using backend: MockAgentBackend) async {
        await backend.enqueueScript([.assistantText(text), .result(sessionId: UUID().uuidString)], forCwd: repo.path)
    }

    private func waitForText(_ text: String, in room: CodingPlanRoom) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while room.liveText != text && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(room.liveText, text)
    }

    private func observeQuestions() async -> Task<Void, Never> {
        state.registerLiveWindow(window)
        let (_, requests) = await state.permission.subscribe()
        return Task { [state] in
            for await request in requests { state?.queuePermissionRequest(request) }
        }
    }

    private func waitForQuestion() async throws -> PermissionRequest {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while window.pendingPermissions.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(window.pendingPermissions.first)
    }

    func testQuestionWaitsBeyondTurnTimeoutAndAnswerSurvivesReload() async throws {
        let observer = await observeQuestions()
        defer { observer.cancel() }
        let writer = backend(.codex)
        let plan = CodingPlan(id: UUID(), goal: "Save settings", source: "",
                              configuration: .init(planner: planner, reviewers: []))
        let room = CodingPlanRoom(plan)
        let id = plan.id.uuidString
        window.currentSessionId = id
        state.threadStore.upsert(ChatSession(id: id, projectId: project.id, title: "Plan").summary)
        state.codingPlanRooms[plan.id] = room
        let run = UUID()
        room.runID = run
        let questions = CodingPlanQuestions(appState: state, room: room, runID: run)
        room.questions = questions
        defer { questions.close() }
        let input: JSONValue = .object(["question": .string("Where should backups live?"),
                                        "options": .array([.string("Locally"), .string("In the cloud")])])
        await writer.enqueueScript([.init(delay: 0, event: .textDelta("Use local backups."), sideEffect: {
            let request = await writer.receivedRequests.last
            let ask = try XCTUnwrap(request?.askUser)
            let result = try await ask(input)
            XCTAssertEqual(result, "User answered: Locally")
        }), .result(sessionId: "draft")], forCwd: repo.path)
        let turn = Task {
            try await state.planningTurn(model: planner, prompt: plan.prompt(for: .draft), cwd: repo.path,
                                         inactivityTimeout: .milliseconds(250), questions: questions)
        }
        defer { turn.cancel() }
        let pending = try await waitForQuestion()
        XCTAssertEqual(pending.sessionId, id)
        XCTAssertEqual(window.presentedPermissionId, pending.id)
        try await Task.sleep(for: .milliseconds(550))
        await state.respondToAskUserQuestion(toolUseId: pending.id, answers: [0: .single("Locally")], in: window)
        let completed = try await turn.value
        XCTAssertEqual(completed.text, "Use local backups.")
        XCTAssertTrue(window.pendingPermissions.isEmpty)
        let saved = try XCTUnwrap(state.threadStore.codingPlan(for: id))
        XCTAssertEqual(saved.contributions.first?.question, "Where should backups live?")
        XCTAssertEqual(saved.contributions.first?.text, "Locally")
        XCTAssertTrue(saved.prompt(for: .reconcile).contains("Where should backups live?\n\nLocally"))
        XCTAssertTrue(saved.prompt(for: .reply).contains("Where should backups live?\n\nLocally"))
        let requests = await writer.receivedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNotNil(requests.first?.ideBridgeCommand)

        var finalTurn = saved
        finalTurn.finish(.reconcile, text: completed.text, at: 0)
        XCTAssertNil(finalTurn.nextStep)
        var withFollowUp = saved
        withFollowUp.contributions.insert(.init(role: "You", model: nil, text: "Also test recovery."), at: 0)
        withFollowUp.finish(.reconcile, text: completed.text, at: 0)
        XCTAssertEqual(withFollowUp.nextStep, .reply)
    }

    func testStoppingOrSkippingAnOpenQuestionLeavesTheDebateResumable() async throws {
        let observer = await observeQuestions()
        defer { observer.cancel() }
        let writer = backend(.codex)
        let input: JSONValue = .object(["question": .string("Which format?"), "options": .array([.string("JSON"), .string("YAML")])])
        for _ in 0..<2 {
            await writer.enqueueScript([.init(delay: 0, event: .textDelta("Draft"), sideEffect: {
                let request = await writer.receivedRequests.last
                _ = try await request?.askUser?(input)
            }), .result(sessionId: "draft")], forCwd: repo.path)
        }
        await answer("Final", using: writer)
        try await state.startCodingPlan(goal: "Save a file", source: "", configuration: .init(planner: planner, reviewers: []),
                                        project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        let room = try XCTUnwrap(state.codingPlanRoom(for: id))
        let first = try await waitForQuestion()
        let stopped = room.task
        room.stop()
        await stopped?.value
        XCTAssertTrue(window.pendingPermissions.isEmpty)
        XCTAssertNil(state.mobilePendingRequests[first.id])
        XCTAssertEqual(room.plan.nextStep, .draft)
        state.resumeCodingPlan(room, cwd: repo.path)
        let second = try await waitForQuestion()
        XCTAssertNotEqual(first.id, second.id)
        await state.skipAskUserQuestion(toolUseId: second.id, in: window)
        await room.task?.value
        XCTAssertNil(room.plan.nextStep)
        XCTAssertNil(room.plan.lastError)
        XCTAssertEqual(room.plan.versions.map(\.markdown), ["Draft", "Final"])
        XCTAssertFalse(room.plan.contributions.contains(where: \.isUserMessage))
    }

    func testReviewerDisconnectingDuringQuestionRetriesWithAnswer() async throws {
        let observer = await observeQuestions()
        defer { observer.cancel() }
        let writer = backend(.codex), critic = backend(.acp)
        await answer("Draft", using: writer)
        await answer("Review retention", using: writer)
        let (disconnect, signal) = AsyncStream<Void>.makeStream()
        await critic.enqueueScript([.result(sessionId: "disconnected", isError: true, sideEffect: {
            for await _ in disconnect { break }
        })], forCwd: repo.path)
        await answer("Keep two copies.", using: critic)
        await answer("Final", using: writer)
        try await state.startCodingPlan(goal: "Plan backups", source: "",
            configuration: .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Check retention.")]),
            project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let room = try XCTUnwrap(state.codingPlanRoom(for: try XCTUnwrap(window.currentSessionId)))
        defer { signal.finish(); room.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await critic.receivedRequests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = await critic.receivedRequests.first
        let ask = try XCTUnwrap(request?.askUser)
        let call = Task { try await ask(.object(["question": .string("How many copies?"),
                                                 "options": .array([.string("One"), .string("Two")])])) }
        defer { call.cancel() }
        let pending = try await waitForQuestion()
        signal.finish()
        while await critic.finalizedStreamIDs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finished = await critic.finalizedStreamIDs
        XCTAssertEqual(finished, [try XCTUnwrap(request?.streamId)])
        await state.respondToAskUserQuestion(toolUseId: pending.id, answers: [0: .single("Two")], in: window)
        let response = try await call.value
        XCTAssertEqual(response, "User answered: Two")
        await room.task?.value
        let reviews = await critic.receivedRequests
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews.last?.prompt.contains("How many copies?\n\nTwo") == true)
        XCTAssertNil(room.plan.lastError)
        XCTAssertNil(room.plan.nextStep)
        XCTAssertEqual(room.plan.contributions.filter(\.isUserMessage).count, 1)
    }

    func testReasoningAndToolEventsKeepLongPlanningTurnsAlive() async throws {
        let writer = backend(.codex)
        await writer.enqueueScript([
            .init(delay: 0.18, event: .thinkingDelta("Reviewing")),
            .init(delay: 0.18, event: .toolCallStarted(id: "1", name: "Read")),
            .init(delay: 0.18, event: .toolCallInput(id: "1", input: [:])),
            .init(delay: 0.18, event: .user(.init(toolUseId: "1", content: "File contents", isError: false))),
            .assistantText("Finished the review", delay: 0.18), .result(sessionId: "review")
        ], forCwd: repo.path)
        let text = try await state.planningText(model: planner, prompt: "Review", cwd: repo.path, inactivityTimeout: .milliseconds(600))
        XCTAssertEqual(text, "Finished the review")
    }

    func testToolCallsStayWithTheirSpeakerAcrossUpdatesAndReload() async throws {
        let writer = backend(.codex), moderator = backend(.claudeCode)
        await writer.enqueueScript([
            .init(delay: 0, event: .unknown(CodexAppServer.claudeToolStart(id: "read", name: "Read"))),
            .init(delay: 0, event: .unknown(CodexAppServer.claudeInputDelta(["path": .string("settings.swift")]))),
            .init(delay: 0, event: .unknown(CodexAppServer.claudeContentBlockStop())),
            .init(delay: 0, event: .toolCallStarted(id: "search", name: "Grep")),
            .init(delay: 0, event: .toolCallInput(id: "search", input: ["pattern": .string("settings")])),
            .init(delay: 0, event: .user(.init(toolUseId: "search", content: "Search failed", isError: true))),
            .init(delay: 0, event: .assistant(.init(role: "assistant", content: [
                .toolUse(id: "read", name: "Read", input: ["offset": .number(10)])
            ]))),
            .init(delay: 0, event: .user(.init(toolUseId: "read", content: "Existing settings", isError: false))),
            .assistantText("Use the existing settings."), .result(sessionId: "draft")
        ], forCwd: repo.path)
        await answer("Approved plan.", using: moderator)
        try await state.startCodingPlan(goal: "Save settings", source: "",
            configuration: .init(planner: planner, hostOverride: host, reviewers: []),
            project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        let room = try XCTUnwrap(state.codingPlanRoom(for: id))
        await room.task?.value

        let saved = try XCTUnwrap(state.threadStore.codingPlan(for: id))
        let tools = try XCTUnwrap(saved.contributions.first?.toolCalls)
        XCTAssertEqual(tools, [
            ToolCall(id: "read", name: "Read", input: ["path": .string("settings.swift"), "offset": .number(10)], result: "Existing settings"),
            ToolCall(id: "search", name: "Grep", input: ["pattern": .string("settings")], result: "Search failed", isError: true)
        ])
        XCTAssertNil(saved.contributions.last?.toolCalls)
        XCTAssertEqual(saved.versions.first?.markdown, "Use the existing settings.")
        let hostPrompt = await moderator.receivedRequests.first?.prompt
        XCTAssertFalse(try XCTUnwrap(hostPrompt).contains("Search failed"))
    }

    func testSilentPlanningTurnReportsInactivityAndCanBeRetried() async throws {
        let writer = backend(.codex)
        let (silence, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        await writer.enqueueScript([.result(sessionId: "stalled", sideEffect: { for await _ in silence {} })], forCwd: repo.path)
        do {
            _ = try await state.planningText(model: planner, prompt: "Review", cwd: repo.path, inactivityTimeout: .milliseconds(150))
            XCTFail("A silent turn should report inactivity")
        } catch let error as PlanningTurnError {
            XCTAssertTrue(error.message.contains("no updates"))
        }
        await answer("Retried review", using: writer)
        let text = try await state.planningText(model: planner, prompt: "Review", cwd: repo.path)
        XCTAssertEqual(text, "Retried review")
    }

    func testMessagesReachTheNextSpeakerAndLateFollowUpsGetAHostReply() async throws {
        let writer = backend(.codex), moderator = backend(.claudeCode)
        let (draftGate, releaseDraft) = AsyncStream<Void>.makeStream()
        let (hostGate, releaseHost) = AsyncStream<Void>.makeStream()
        defer {
            releaseDraft.finish()
            releaseHost.finish()
        }
        await writer.enqueueScript([.init(delay: 0, event: .textDelta("Initial plan")),
            .result(sessionId: "draft", sideEffect: { for await _ in draftGate {} })], forCwd: repo.path)
        await moderator.enqueueScript([.init(delay: 0, event: .textDelta("Save a backup.")),
            .result(sessionId: "final", sideEffect: { for await _ in hostGate {} })], forCwd: repo.path)
        await answer("A backup allows recovery.", using: moderator)
        try await state.startCodingPlan(goal: "Save settings", source: "",
            configuration: .init(planner: planner, hostOverride: host, reviewers: []),
            project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        let room = try XCTUnwrap(state.codingPlanRoom(for: id))
        try await waitForText("Initial plan", in: room)
        try state.sendCodingPlanMessage("  Save a backup.  ", to: room, cwd: repo.path)
        try state.sendCodingPlanMessage(" \n ", to: room, cwd: repo.path)
        let stored = try XCTUnwrap(state.threadStore.codingPlan(for: id))
        XCTAssertEqual(stored.contributions.map(\.text), ["Save a backup."])
        XCTAssertEqual(stored.nextStep, .draft)
        releaseDraft.finish()
        try await waitForText("Save a backup.", in: room)
        try state.sendCodingPlanMessage("Why a backup?", to: room, cwd: repo.path)
        try state.sendCodingPlanMessage("Explain recovery.", to: room, cwd: repo.path)
        releaseHost.finish()
        await room.task?.value
        let requests = await moderator.receivedRequests
        XCTAssertEqual(requests.count, 2)
        let finalPrompt = try XCTUnwrap(requests.first?.prompt)
        XCTAssertTrue(finalPrompt.contains("Save a backup."))
        XCTAssertFalse(finalPrompt.contains("Explain recovery."))
        XCTAssertTrue(try XCTUnwrap(requests.last?.prompt).contains("You: Why a backup?\n\nYou: Explain recovery."))
        XCTAssertEqual(room.plan.contributions.map(\.role), ["Planner", "You", "Host", "You", "You", "Host"])
        XCTAssertEqual(room.plan.versions.count, 2)
        XCTAssertNil(room.plan.nextStep)

        state.codingPlanRooms.removeAll()
        let reopened = try XCTUnwrap(state.codingPlanRoom(for: id))
        await answer("Keep two copies.\n```suggestion\nSave a backup.\n---\nSave two backups.\n```", using: moderator)
        try state.sendCodingPlanMessage("Keep two copies.", to: reopened, cwd: repo.path)
        await reopened.task?.value
        let followUp = await moderator.receivedRequests.last
        XCTAssertTrue(try XCTUnwrap(followUp).prompt.contains("Host: A backup allows recovery."))
        XCTAssertEqual(reopened.plan.versions.last?.markdown, "Save two backups.")
        XCTAssertEqual(reopened.plan.contributions.last?.versionID, reopened.plan.versions.last?.id)
        XCTAssertEqual(state.threadStore.codingPlan(for: id)?.versions.last?.edits.first?.comment, "Keep two copies.")
    }

    func testMessageOnReadyPlanReopensDebateWithEveryReviewer() async throws {
        let moderator = backend(.claudeCode), critic = backend(.acp)
        var plan = CodingPlan(id: UUID(), goal: "Save files", source: "",
            configuration: .init(planner: planner, hostOverride: host, reviewers: [
                .init(model: reviewer, prompt: "Check writes"), .init(model: reviewer, prompt: "Check recovery")
            ]))
        plan.finish(.draft, text: "Original draft")
        plan.finish(.moderate, text: "Initial agenda")
        plan.finish(.review(0), text: "Writes checked")
        plan.finish(.review(1), text: "Recovery checked")
        plan.finish(.reconcile, text: "Latest plan")
        state.threadStore.upsert(ChatSession(id: plan.id.uuidString, projectId: project.id, title: "Plan").summary)
        try state.threadStore.saveCodingPlan(plan)
        let room = try XCTUnwrap(state.codingPlanRoom(for: plan.id.uuidString))

        await answer("Consider backups", using: moderator)
        await answer("Write two copies", using: critic)
        await answer("Test restoring a copy", using: critic)
        await answer("Plan with backups", using: moderator)
        try state.sendCodingPlanMessage("How should we handle backups?", to: room, cwd: repo.path)
        await room.task?.value

        let reviews = await critic.receivedRequests
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews.allSatisfy { $0.prompt.contains("Latest plan") && $0.prompt.contains("How should we handle backups?") })
        XCTAssertTrue(reviews.last?.prompt.contains("Write two copies") == true)
        let saved = try XCTUnwrap(state.threadStore.codingPlan(for: plan.id.uuidString))
        XCTAssertEqual(saved.contributions.dropFirst(plan.contributions.count).map(\.role),
                       ["You", "Host", "Reviewer 1", "Reviewer 2", "Host"])
        XCTAssertEqual(saved.versions.last?.markdown, "Plan with backups")
        XCTAssertEqual(saved.planningStatus, "ready")
    }

    func testReviewersAddedDuringDraftAndHostTurnsRunOnceInOrder() async throws {
        let writer = backend(.codex), moderator = backend(.claudeCode), critic = backend(.acp)
        let (draftGate, releaseDraft) = AsyncStream<Void>.makeStream()
        let (hostGate, releaseHost) = AsyncStream<Void>.makeStream()
        defer { releaseDraft.finish(); releaseHost.finish() }
        await writer.enqueueScript([.init(delay: 0, event: .textDelta("Draft")),
            .result(sessionId: "draft", sideEffect: { for await _ in draftGate {} })], forCwd: repo.path)
        await answer("Agenda", using: moderator)
        await answer("Initial review", using: critic)
        await moderator.enqueueScript([.init(delay: 0, event: .textDelta("First host plan")),
            .result(sessionId: "host", sideEffect: { for await _ in hostGate {} })], forCwd: repo.path)
        await answer("Second review", using: critic)
        await answer("Third review", using: critic)
        await answer("Final host plan", using: moderator)

        try await state.startCodingPlan(goal: "Plan storage", source: "",
            configuration: .init(planner: planner, hostOverride: host, reviewers: []),
            project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        let room = try XCTUnwrap(state.codingPlanRoom(for: id))
        try await waitForText("Draft", in: room)
        try state.addCodingPlanReviewer(.init(model: reviewer, prompt: "Check writes."), to: room, cwd: repo.path)
        XCTAssertEqual(room.plan.nextStep, .draft)
        releaseDraft.finish()

        try await waitForText("First host plan", in: room)
        let second = CodingPlan.Reviewer(model: reviewer, prompt: "Check recovery.")
        let third = CodingPlan.Reviewer(model: reviewer, prompt: "Check reloads.")
        for addition in [second, second, third] {
            try state.addCodingPlanReviewer(addition, to: room, cwd: repo.path)
        }
        var saved = try XCTUnwrap(state.threadStore.codingPlan(for: id))
        XCTAssertEqual(saved.nextStep, .reconcile)
        XCTAssertEqual(saved.completedReviewerCount, 1)
        saved.finish(.reconcile, text: "First host plan")
        XCTAssertEqual(saved.nextStep, .review(1))
        releaseHost.finish()
        await room.task?.value

        let reviews = await critic.receivedRequests
        let hostTurns = await moderator.receivedRequests
        XCTAssertEqual(reviews.count, 3)
        XCTAssertTrue(hostTurns.first?.prompt.contains("Check writes.") == true)
        XCTAssertTrue(reviews.dropFirst().first?.prompt.contains("First host plan") == true)
        XCTAssertTrue(reviews.dropFirst().first?.prompt.contains("Check recovery.") == true)
        XCTAssertTrue(reviews.last?.prompt.contains("Check reloads.") == true)
        XCTAssertTrue(hostTurns.last?.prompt.contains("Third review") == true)
        XCTAssertEqual(room.plan.contributions.map(\.role), ["Planner", "Host", "Reviewer 1", "Host", "Reviewer 2", "Reviewer 3", "Host"])
        XCTAssertEqual(room.plan.completedReviewerCount, 3)
        XCTAssertNil(room.plan.nextStep)
    }

    func testLateReviewersWaitForRequestedHostRevisionAndFollowUp() {
        var plan = CodingPlan(id: UUID(), goal: "Save settings", source: "",
                              configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "Draft")
        plan.finish(.reconcile, text: "Host plan")
        let revision = CodingPlan.Step.revise("Save a backup")
        plan.nextStep = revision
        plan.addReviewer(.init(model: reviewer, prompt: "Review backups."))
        let turnStart = plan.contributions.endIndex
        plan.contributions.append(.init(role: "You", model: nil, text: "Which folder?"))
        plan.finish(revision, text: "Revised backup plan", at: turnStart)
        XCTAssertEqual(plan.nextStep, .moderate)
        XCTAssertTrue(plan.prompt(for: .moderate).contains("Which folder?"))
        plan.addReviewer(.init(model: reviewer, prompt: "Review folders."))
        plan.finish(.moderate, text: "Review folder selection.")
        XCTAssertEqual(plan.nextStep, .review(0))
        XCTAssertTrue(plan.prompt(for: .review(0)).contains("Revised backup plan"))
        plan.finish(.review(0), text: "Backups covered.")
        XCTAssertEqual(plan.nextStep, .review(1))
        plan.finish(.review(1), text: "Folder covered.")
        XCTAssertEqual(plan.nextStep, .reconcile)
        plan.finish(.reconcile, text: "Reviewed plan")
        XCTAssertNil(plan.nextStep)
    }

    func testAddingToReadyAndPausedPlansPreservesEarlierReviewsAndManualRevisions() async throws {
        let writer = backend(.codex), critic = backend(.acp)
        var plan = CodingPlan(id: UUID(), goal: "Store backups", source: "",
                              configuration: .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Check writes.")]))
        plan.finish(.draft, text: "Draft")
        plan.finish(.moderate, text: "Agenda")
        plan.finish(.review(0), text: "First review")
        plan.finish(.reconcile, text: "Host plan")
        plan.edit(markdown: "Use the revised backup directory.")
        let id = plan.id.uuidString
        state.threadStore.upsert(ChatSession(id: id, projectId: project.id, title: "Plan").summary)
        try state.threadStore.saveCodingPlan(plan)
        var room = try XCTUnwrap(state.codingPlanRoom(for: id))
        await critic.enqueueScript([.result(sessionId: "failed", isError: true)], forCwd: repo.path)
        try state.addCodingPlanReviewer(.init(model: reviewer, prompt: "Check the directory."), to: room, cwd: repo.path)
        await room.task?.value
        XCTAssertNotNil(room.plan.lastError)
        XCTAssertEqual(room.plan.nextStep, .review(1))

        state.codingPlanRooms.removeAll()
        room = try XCTUnwrap(state.codingPlanRoom(for: id))
        let addition = CodingPlan.Reviewer(model: planner, prompt: "Check permissions.")
        room.isHandingOff = true
        XCTAssertThrowsError(try state.addCodingPlanReviewer(addition, to: room, cwd: repo.path))
        room.isHandingOff = false
        try state.addCodingPlanReviewer(addition, to: room, cwd: repo.path)
        XCTAssertNil(room.runID)
        XCTAssertEqual(room.plan.nextStep, .review(1))
        let saved = try XCTUnwrap(state.threadStore.codingPlan(for: id))
        XCTAssertEqual(saved.configuration.reviewers.last?.id, addition.id)
        XCTAssertEqual(saved.configuration.reviewers.last?.model, planner)
        XCTAssertEqual(saved.configuration.reviewers.last?.prompt, addition.prompt)
        await answer("Directory reviewed", using: critic)
        await answer("Permissions reviewed", using: writer)
        await answer("Updated plan", using: writer)
        state.resumeCodingPlan(room, cwd: repo.path)
        await room.task?.value

        let reviews = await critic.receivedRequests
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews.allSatisfy { $0.prompt.contains("Use the revised backup directory.") })
        XCTAssertEqual(room.plan.contributions.dropFirst(plan.contributions.count).map(\.role), ["Reviewer 2", "Reviewer 3", "Host"])
        XCTAssertEqual(room.plan.versions.last?.markdown, "Updated plan")
        XCTAssertNil(room.plan.nextStep)
    }

    func testDebateQuestionListenersSkipBusyPortsAndShareConcurrentRequestsForOneSession() async throws {
        let first = IDEMCPServer(), second = IDEMCPServer()
        let firstPort = await first.allocate(sessionKey: "first", capabilities: [])
        async let other = second.allocate(sessionKey: "second", capabilities: [])
        async let reused = second.allocate(sessionKey: "second", capabilities: [])
        let (otherPort, reusedPort) = await (other, reused)
        await first.release(sessionKey: "first")
        await second.release(sessionKey: "second")
        XCTAssertNotEqual(try XCTUnwrap(firstPort), try XCTUnwrap(otherPort))
        XCTAssertEqual(otherPort, reusedPort)
    }

    func testFailedReviewerResumesWithoutReplayingTheDraftOrAgenda() async throws {
        let writer = backend(.codex), critic = backend(.acp)
        await answer("Draft once", using: writer)
        await answer("Review this design", using: writer)
        await critic.enqueueScript([.result(sessionId: "failed", isError: true)], forCwd: repo.path)
        let config = CodingPlan.Configuration(planner: planner, reviewers: [.init(model: reviewer, prompt: "Review it")])
        try await state.startCodingPlan(goal: "Goal", source: "", configuration: config,
                                        project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        var room = try XCTUnwrap(state.codingPlanRoom(for: id))
        await room.task?.value
        XCTAssertEqual(room.plan.nextStep, .review(0))
        XCTAssertNotNil(room.plan.lastError)
        let summary = try XCTUnwrap(state.allSessionSummaries.first { $0.id == id })
        XCTAssertTrue(state.isThreadInterrupted(summary))
        state.codingPlanRooms.removeAll()
        state.briefingPlans = try await state.codingPlanActivities()
        XCTAssertTrue(state.isThreadInterrupted(summary))
        room = try XCTUnwrap(state.codingPlanRoom(for: id))
        await answer("Reviewed", using: critic)
        await answer("Finished", using: writer)
        try state.sendCodingPlanMessage("Check reopening too.", to: room, cwd: repo.path)
        state.resumeCodingPlan(room, cwd: repo.path)
        XCTAssertFalse(state.isThreadInterrupted(summary))
        await room.task?.value
        let writerRequests = await writer.receivedRequests
        let criticRequests = await critic.receivedRequests
        XCTAssertEqual(writerRequests.count, 3)
        XCTAssertEqual(criticRequests.count, 2)
        XCTAssertTrue(criticRequests.last?.prompt.contains("Check reopening too.") == true)
        XCTAssertTrue(writerRequests.last?.prompt.contains("Check reopening too.") == true)
        XCTAssertEqual(room.plan.versions.map(\.markdown), ["Draft once", "Finished"])
        XCTAssertNil(room.plan.nextStep)
        XCTAssertNil(room.plan.lastError)
    }

    func testCodexMessageBoundariesKeepProgressOutOfTheFinalPlan() async throws {
        let writer = backend(.codex)
        await writer.enqueueScript([
            .init(delay: 0, event: .textDelta("Checking the files.")),
            .init(delay: 0, event: .unknown(#"{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"commentary","text":"Checking the files."}}}"#)),
            .init(delay: 0, event: .unknown(#"{"method":"item/started","params":{"item":{"type":"agentMessage","phase":"final_answer"}}}"#)),
            .init(delay: 0, event: .textDelta("# Plan")),
            .init(delay: 0, event: .unknown(##"{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"# Plan"}}}"##)),
            .result(sessionId: "draft")
        ], forCwd: repo.path)
        let markdown = try await state.planningText(model: planner, prompt: "Draft a plan", cwd: repo.path)
        XCTAssertEqual(markdown, "# Plan")
    }

    func testStoppingALiveDraftResumesFromTheLastCompletedTurn() async throws {
        let writer = backend(.codex), critic = backend(.acp)
        await writer.enqueueScript([
            .init(delay: 0, event: .textDelta("Partial draft")),
            .assistantText("Abandoned draft", delay: 0.5), .result(sessionId: "stopped")
        ], forCwd: repo.path)
        let config = CodingPlan.Configuration(planner: planner, reviewers: [.init(model: reviewer, prompt: "Check tests")])
        try await state.startCodingPlan(goal: "Add a test", source: "", configuration: config,
                                        project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        let room = try XCTUnwrap(state.codingPlanRoom(for: id))
        try await waitForText("Partial draft", in: room)
        XCTAssertTrue(room.plan.versions.isEmpty)
        let stopped = room.task
        room.stop()
        XCTAssertEqual(room.liveText, "")
        XCTAssertEqual(state.threadStore.codingPlan(for: id)?.nextStep, .draft)

        await answer("Replacement draft", using: writer)
        await answer("Review the test", using: writer)
        await answer("Reviewed", using: critic)
        await answer("Approved test plan", using: writer)
        state.resumeCodingPlan(room, cwd: repo.path)
        await room.task?.value
        await stopped?.value
        XCTAssertNil(room.plan.lastError)
        XCTAssertNil(room.plan.nextStep)
        XCTAssertEqual(state.threadStore.codingPlan(for: id)?.versions.map(\.markdown), ["Replacement draft", "Approved test plan"])
    }

    func testBroadcastAndHostReasonsSurviveReloadOutsideThePlan() throws {
        var plan = CodingPlan(id: UUID(), goal: "Edit", source: "", configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "On air: Starting with two stages.\nBuild once.\n\nShip immediately.")
        plan.finish(.revise("Make delivery safer."), text: """
            On air: The host added checks before delivery.
            Edit reason: Rebuilding catches stale assets.
            Build twice.

            Edit reason: Verification protects the release.
            Ship after verification.
            """)
        let saved = try JSONDecoder().decode(CodingPlan.self, from: JSONEncoder().encode(plan))
        let version = try XCTUnwrap(saved.versions.last)
        XCTAssertEqual(version.markdown, "Build twice.\n\nShip after verification.")
        XCTAssertEqual(version.edits.compactMap(\.comment), ["Rebuilding catches stale assets.", "Verification protects the release."])
        XCTAssertEqual(version.edits.first?.userComments, ["Make delivery safer."])
        XCTAssertEqual(saved.contributions.last?.briefing, "The host added checks before delivery.")
    }

    func testRadioPublishesBriefingBeforeDraftFinishes() async throws {
        let writer = backend(.codex)
        await writer.enqueueScript([.init(delay: 0, event: .textDelta("On air: Start with recovery.\n# Draft")),
                                    .result(sessionId: "draft", delay: 0.6)], forCwd: repo.path)
        await answer("On air: The recovery check is ready.\n# Final", using: writer)
        try await state.startCodingPlan(goal: "Review recovery", source: "", configuration: .init(planner: planner, reviewers: []),
                                        project: project, worktreePath: nil, worktreeBranch: nil, in: window)
        let id = try XCTUnwrap(window.currentSessionId)
        let room = try XCTUnwrap(state.codingPlanRoom(for: id))
        try await waitForText("# Draft", in: room)
        XCTAssertEqual(room.dispatch?.text, "Planner. Start with recovery.")
        XCTAssertTrue(room.plan.versions.isEmpty)
        await room.task?.value
        XCTAssertEqual(room.dispatch?.text, "Host. The recovery check is ready.")
        XCTAssertEqual(state.threadStore.codingPlan(for: id)?.versions.last?.markdown, "# Final")
    }

    func testLiveRadioWaitsForCompleteDispatchAndPreservesCode() {
        let partial = CodingPlanBroadcast("On air: We need", hostRevision: false, streaming: true)
        XCTAssertNil(partial.briefing)
        XCTAssertTrue(partial.body.isEmpty)
        let code = "```text\nEdit reason: example\n```\n"
        let complete = CodingPlanBroadcast("On air: Explain the syntax.\n" + code, hostRevision: true)
        XCTAssertEqual(complete.briefing, "Explain the syntax.")
        XCTAssertEqual(complete.body, code)
        XCTAssertEqual(CodingPlanBroadcast(code, hostRevision: false).body, code)
    }

    func testGlobalHistoryConversionUsesSelectedAgentAndRealDestinationProject() async throws {
        let chat = state.globalChatProject
        let session = ChatSession(id: UUID().uuidString, projectId: chat.id, title: "Cache request",
                                  messages: [ChatMessage(role: .user, content: "Save the cache atomically.")],
                                  agentProvider: .acp, model: reviewer.id, origin: .legacyRxCode)
        state.allSessionSummaries = [session.summary]
        await persistence.stubFullSession(session)
        let source = try await state.chatCreationSource(.init(.task, sessionID: session.id), in: window)
        XCTAssertEqual(source.model.id, reviewer.id)
        XCTAssertEqual(source.project.id, Project.globalChatID)
        XCTAssertTrue(source.transcript.contains("Save the cache atomically."))
        let chosen = backend(.codex)
        await answer("Task title\n\nTask details", using: chosen)
        await answer("Story title\n\nStory scope", using: chosen)
        let task = try await state.boardDraftFromChat(source, isStory: false, project: project, model: planner)
        let story = try await state.boardDraftFromChat(source, isStory: true, project: project, model: planner)
        guard case .task(let t, .form) = task, case .story(let s, .form) = story else { return XCTFail("Expected editable drafts") }
        XCTAssertEqual(t.sourceSessionKey, session.id)
        XCTAssertEqual(t.projectId, project.id)
        XCTAssertEqual(t.title, "Task title")
        XCTAssertEqual(t.details, "Task details")
        XCTAssertEqual(s.details, "Story scope")
        let requests = await chosen.receivedRequests
        XCTAssertTrue(requests.allSatisfy { $0.model == planner.id && $0.prompt.contains(source.transcript) })
        XCTAssertNil(state.task(id: t.id))
        XCTAssertFalse(state.stories().contains { $0.id == s.id })
    }
}
