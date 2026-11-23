import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class CodingPlanTests: XCTestCase {
    private let planner = AgentModel(provider: .codex, id: "planner", displayName: "Planner model")
    private let host = AgentModel(provider: .claudeCode, id: "host", displayName: "Host model")
    private let reviewer = AgentModel(provider: .acp, id: "test::review", displayName: "Review model")
    private var state: AppState!
    private var window: WindowState!
    private var project: Project!
    private var repo: URL!
    private var persistence: MockAppStatePersistence!
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

    private func backend(_ provider: AgentProvider) -> MockAgentBackend {
        let mock = MockAgentBackend(provider: provider)
        state.agentBackendOverrides[provider] = mock
        return mock
    }

    private func answer(_ text: String, using backend: MockAgentBackend) async {
        await backend.enqueueScript([.assistantText(text), .result(sessionId: UUID().uuidString)], forCwd: repo.path)
    }

    private func waitForText(_ text: String, in room: CodingPlanRoom) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while room.liveText != text && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(room.liveText, text)
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

    func testDebateStreamsOncePerRoleAndHandsOnlyTheChosenVersionToFreshThread() async throws {
        let writer = backend(.codex), moderator = backend(.claudeCode), critic = backend(.acp)
        let implementer = backend(.flowcy)
        let first = "## Storage\n\nUse a file. Reopen the project."
        await writer.enqueueScript([
            .init(delay: 0, event: .textDelta(first)), .assistantText(first), .result(sessionId: "writer-native")
        ], forCwd: repo.path)
        await answer("Check interrupted writes.", using: moderator)
        await answer("Handle interruptions.\n```suggestion\nUse a file.\n---\nWrite atomically.\n```", using: critic)
        await answer("The revised draft also needs a reload check.", using: critic)
        await answer("## Implementation\n\nWrite atomically and test reopening.", using: moderator)

        let config = CodingPlan.Configuration(planner: planner, hostOverride: host, reviewers: [
            .init(model: reviewer, prompt: "Audit persistence"), .init(model: reviewer, prompt: "Audit reloads")
        ])
        try await state.startCodingPlan(goal: "Persist settings", source: "Original chat marker", configuration: config,
                                        project: project, worktreePath: repo.path, worktreeBranch: "feature", in: window)
        let sourceID = try XCTUnwrap(window.currentSessionId)
        var room = try XCTUnwrap(state.codingPlanRoom(for: sourceID))
        await room.task?.value
        XCTAssertNil(room.plan.lastError)
        XCTAssertNil(room.plan.nextStep)
        XCTAssertEqual(room.plan.contributions.map(\.role), ["Planner", "Host", "Reviewer 1", "Reviewer 2", "Host"])
        XCTAssertEqual(room.plan.versions.map(\.title), ["Planner draft", "Reviewer 1 proposal", "Host plan"])
        XCTAssertEqual(room.plan.versions.first?.markdown, first)
        XCTAssertEqual(room.plan.versions[1].markdown, "## Storage\n\nWrite atomically. Reopen the project.")
        let reviews = await critic.receivedRequests
        XCTAssertEqual(reviews.map(\.model), ["review", "review"])
        XCTAssertEqual(reviews.first?.acpSpec?.id, "test")
        XCTAssertTrue(reviews[0].prompt.contains("Audit persistence"))
        XCTAssertTrue(reviews[1].prompt.contains("Audit reloads"))
        XCTAssertTrue(reviews[1].prompt.contains("Write atomically. Reopen"))
        XCTAssertTrue(reviews[0].prompt.contains("Check interrupted writes."))
        XCTAssertTrue(reviews.allSatisfy { $0.isEphemeral && $0.sessionId == nil && $0.planMode && $0.permissionMode == .plan })
        XCTAssertNotEqual(reviews[0].clientSessionKey, reviews[1].clientSessionKey)

        state.codingPlanRooms.removeAll()
        room = try XCTUnwrap(state.codingPlanRoom(for: sourceID))
        let hostVersion = try XCTUnwrap(room.plan.versions.last)
        try state.reviseCodingPlan(room, base: hostVersion.id, text: "Manually edited plan", askHost: false, cwd: repo.path)
        let edited = try XCTUnwrap(room.plan.versions.last)
        XCTAssertThrowsError(try state.reviseCodingPlan(room, base: hostVersion.id, text: "Stale edit", askHost: false, cwd: repo.path))
        await answer("Newer host-only revision", using: moderator)
        try state.reviseCodingPlan(room, base: edited.id, text: "Another approach", askHost: true, cwd: repo.path)
        await room.task?.value
        XCTAssertEqual(room.plan.versions.last?.markdown, "Newer host-only revision")
        let resultID = UUID().uuidString
        await implementer.enqueueScript([.systemInit(sessionId: resultID), .assistantText("Implemented"), .result(sessionId: resultID)], forCwd: repo.path)
        let implementationModel = AgentModel(provider: .flowcy, id: "implementation", displayName: "Implementation model")
        let stream = await state.implementCodingPlan(room, versionID: edited.id, model: implementationModel, in: window)
        let finished = await state.awaitStreamCompletion(streamId: try XCTUnwrap(stream), timeout: 10, acceptsPartial: false)
        XCTAssertNotNil(finished)
        let requests = await implementer.receivedRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.prompt, CodingPlan.implementationPrompt(for: edited))
        XCTAssertNil(request.sessionId)
        XCTAssertTrue(request.history.isEmpty)
        XCTAssertFalse(request.planMode)
        XCTAssertFalse(request.isEphemeral)
        XCTAssertEqual(request.model, implementationModel.id)
        XCTAssertEqual(request.cwd, repo.path)
        XCTAssertEqual(state.threadStore.implementationThread(for: room.plan.id), resultID)
        XCTAssertEqual(window.currentSessionId, resultID)
        XCTAssertEqual(state.messages(in: window).filter { $0.role == .user }.map(\.content), [request.prompt])
        XCTAssertEqual(state.threadStore.codingPlan(for: sourceID)?.approvedVersionID, edited.id)
        state.codingPlanRooms.removeAll()
        let archive = try XCTUnwrap(state.codingPlanRoom(for: resultID))
        XCTAssertEqual(archive.plan.approvedVersionID, edited.id)
        XCTAssertEqual(archive.plan.versions.count, 5)
        XCTAssertThrowsError(try state.sendCodingPlanMessage("Change the approved plan", to: archive, cwd: repo.path))
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
        state.codingPlanRooms.removeAll()
        room = try XCTUnwrap(state.codingPlanRoom(for: id))
        await answer("Reviewed", using: critic)
        await answer("Finished", using: writer)
        try state.sendCodingPlanMessage("Check reopening too.", to: room, cwd: repo.path)
        state.resumeCodingPlan(room, cwd: repo.path)
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

    func testEarlierDebatesRecoverTheirExactMessageVersionLinks() throws {
        var plan = CodingPlan(id: UUID(), goal: "Persist preferences", source: "", configuration:
            .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Review writes")]))
        plan.finish(.draft, text: "Save settings.")
        plan.finish(.moderate, text: "Host answer")
        plan.finish(.review(0), text: "```suggestion\nSave settings.\n---\nSave atomically.\n```")
        plan.finish(.reconcile, text: "Host answer")
        plan.edit(markdown: "My version")
        let expected = plan.versions.map(\.id)
        for index in plan.contributions.indices { plan.contributions[index].versionID = nil }
        var decoded = try JSONDecoder().decode(CodingPlan.self, from: JSONEncoder().encode(plan))
        decoded.restoreVersionLinks()
        XCTAssertEqual(decoded.contributions.map(\.versionID), [expected[0], nil, expected[1], expected[2], expected[3]])
    }

    func testReloadKeepsQuotedPlanTextInItsOwnChatBubble() {
        var plan = CodingPlan(id: UUID(), goal: "Edit", source: "", configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "Draft")
        plan.finish(.reconcile, text: "Final")
        plan.contributions.append(.init(role: "You", model: nil, text: "Edited the implementation plan."))
        plan.finish(.reply, text: "Save two copies.")
        plan.edit(markdown: "Manual edit")
        plan.contributions.append(.init(role: "You", model: nil, text: "How should we store it?"))
        plan.finish(.reply, text: "Save two copies.")
        plan.finish(.revise("Add backups"), text: "Save two copies.")
        let links = plan.contributions.map(\.versionID)
        plan.restoreVersionLinks()
        XCTAssertEqual(plan.contributions.map(\.versionID), links)
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

    func testSuggestionsRequireCompletedUniqueNonoverlappingQuotes() {
        let review = CodingPlanReview("""
        Findings
        ```suggestion
        one
        ---
        ONE
        ```
        ```suggestion
        repeat
        ---
        duplicate
        ```
        ```suggestion
        on
        ---
        overlapping
        ```
        ```suggestion
        two
        ---
        unfinished
        """)
        let result = review.applying(to: "one two repeat repeat")
        XCTAssertEqual(result.markdown, "ONE two repeat repeat")
        XCTAssertEqual(result.edits.count, 1)
        XCTAssertEqual(review.commentary, "Findings")
    }

    func testInlineReviewCommentsSurviveReloadAndStayWithTheirPassage() throws {
        let id = UUID()
        let session = ChatSession(id: id.uuidString, projectId: project.id, title: "Review", messages: [])
        state.threadStore.upsert(session.summary)
        var plan = CodingPlan(id: id, goal: "Review", source: "", configuration:
            .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Review")]))
        plan.finish(.draft, text: "👩‍💻 Keep one and two. Remove this.")
        plan.finish(.review(0), text: """
        This is redundant.
        ```suggestion
         Remove this.
        ---
        ```
        Use the same term here.
        ```suggestion
        two
        ---
        one
        ```
        """)
        let room = CodingPlanRoom(plan)
        let proposal = try XCTUnwrap(plan.versions.last)
        XCTAssertEqual(proposal.markdown, "👩‍💻 Keep one and one.")
        XCTAssertEqual(proposal.edits.map(\.comment), ["Use the same term here.", "This is redundant."])
        let source = proposal.markdown as NSString
        XCTAssertEqual(proposal.edits[0].range, source.range(of: "one", options: .backwards))
        XCTAssertEqual(proposal.edits[1].range, NSRange(location: source.length, length: 0))
        try state.addCodingPlanComment(" Keep this wording. ", to: 0, in: proposal.id, room: room)
        let stored = try XCTUnwrap(state.threadStore.codingPlan(for: id.uuidString)?.versions.last)
        XCTAssertEqual(stored.edits[0].userComments, ["Keep this wording."])
        XCTAssertNil(stored.edits[1].userComments)
        XCTAssertEqual(stored.markdown, proposal.markdown)
        XCTAssertThrowsError(try state.addCodingPlanComment(" ", to: 0, in: proposal.id, room: room))
        XCTAssertThrowsError(try state.addCodingPlanComment("Stale", to: 3, in: proposal.id, room: room))

        // Strip the new optional fields to exercise existing debates on disk.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var versions = try XCTUnwrap(json["versions"] as? [[String: Any]])
        versions[1]["edits"] = proposal.edits.map { ["original": $0.original, "replacement": $0.replacement] }
        json["versions"] = versions
        var legacy = try JSONDecoder().decode(CodingPlan.self, from: JSONSerialization.data(withJSONObject: json))
        legacy.restoreVersionLinks()
        XCTAssertEqual(legacy.versions.last?.edits, proposal.edits)
        versions[1].removeValue(forKey: "edits")
        json["versions"] = versions
        var untracked = try JSONDecoder().decode(CodingPlan.self, from: JSONSerialization.data(withJSONObject: json))
        untracked.restoreVersionLinks()
        XCTAssertEqual(untracked.versions.last?.edits, proposal.edits)
    }

    func testManualAndHostRevisionsRoundTripExactMarkdownWithComments() throws {
        var plan = CodingPlan(id: UUID(), goal: "Edit", source: "", configuration: .init(planner: planner, reviewers: []))
        let original = "# Plan\n\nKeep 📝 then remove this paragraph.\n\n- Finish now."
        let revised = "# Plan\n\nKeep 📝 then **save twice**.\n\n- Finish later.\n"
        plan.finish(.draft, text: original)
        plan.edit(markdown: revised, comment: "Exercise recovery.")
        plan.finish(.revise("Check the reload."), text: revised + "\nReload.")
        for (index, note) in [(1, "Exercise recovery."), (2, "Check the reload.")] {
            let version = plan.versions[index]
            let restored = NSMutableString(string: version.markdown)
            XCTAssertFalse(version.edits.isEmpty)
            for edit in version.edits.reversed() {
                let range = try XCTUnwrap(edit.range)
                XCTAssertEqual(restored.substring(with: range), edit.replacement)
                XCTAssertEqual(edit.userComments, [note])
                restored.replaceCharacters(in: range, with: edit.original)
            }
            XCTAssertEqual(restored as String, plan.versions[index - 1].markdown)
        }
        XCTAssertEqual(CodingPlan.implementationPrompt(for: plan.versions[1]), "Implement this approved plan and verify the result.\n\n" + revised)
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

extension CodingPlanTests {
    private func callPlanTool(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        let result = try await state.ideHandleToolCall(name: name, arguments: .object(args), sessionKey: "plan-reader-test")
        let body = try XCTUnwrap(result["content"]?[0]?["text"]?.stringValue)
        return try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
    }

    func testPlanToolsDiscoverPersistedHistoryAndRetrieveUnabridgedContent() async throws {
        var plan = CodingPlan(id: UUID(), goal: "Extension kit", source: "", configuration: .init(planner: planner, reviewers: []))
        let source = ChatSession(id: plan.id.uuidString, projectId: project.id, title: "Extension kit",
                                 messages: [.init(role: .user, content: plan.goal)])
        state.threadStore.upsert(source.summary)
        await persistence.stubFullSession(source)
        let draft = "# Draft\n\n" + String(repeating: "- Feature A\n", count: 300)
        plan.finish(.draft, text: draft)
        plan.finish(.reconcile, text: "# Final\n\n- Feature B")
        try state.threadStore.saveCodingPlan(plan)
        XCTAssertNil(state.codingPlanRooms[plan.id])

        let discovered = try await callPlanTool("ide__list_coding_plans", ["project_id": .string(project.id.uuidString)])
        let summary = try XCTUnwrap(discovered["plans"]?[0])
        XCTAssertEqual(summary["plan_id"]?.stringValue, plan.id.uuidString)
        XCTAssertEqual(summary["planning_status"]?.stringValue, "ready")
        XCTAssertEqual(summary["implementation_status"]?.stringValue, "unimplemented")
        XCTAssertEqual(summary["version_count"]?.numberValue, 2)
        XCTAssertEqual(summary["current_version_id"]?.stringValue, plan.versions[1].id.uuidString)
        XCTAssertNil(state.codingPlanRooms[plan.id], "Discovery must not open the debate room.")

        let page = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString), "limit": .number(1)])
        XCTAssertEqual(page["versions"]?[0]?["title"]?.stringValue, "Host plan")
        XCTAssertEqual(page["versions"]?[0]?["is_current"]?.boolValue, true)
        XCTAssertEqual(page["next_offset"]?.numberValue, 1)
        let second = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString), "offset": .number(1)])
        XCTAssertEqual(second["versions"]?[0]?["version_id"]?.stringValue, plan.versions[0].id.uuidString)
        let result = try await callPlanTool("ide__get_coding_plan_version", [
            "plan_id": .string(plan.id.uuidString), "version_id": .string(plan.versions[0].id.uuidString)])
        XCTAssertEqual(result["version"]?["markdown"]?.stringValue, draft)

        let room = try XCTUnwrap(state.codingPlanRoom(for: source.id))
        room.plan.lastError = "Review was interrupted"
        let hydrated = try await callPlanTool("ide__list_coding_plans", ["thread_id": .string(source.id)])
        XCTAssertEqual(hydrated["plans"]?[0]?["planning_status"]?.stringValue, "interrupted")
        let wrongProject = try await callPlanTool("ide__list_coding_plans", ["project_id": .string(UUID().uuidString), "thread_id": .string(source.id)])
        XCTAssertEqual(wrongProject["total"]?.numberValue, 0)
    }

    func testPlanToolsDeduplicateHandoffAndRequireImplementationEvidence() async throws {
        var plan = CodingPlan(id: UUID(), goal: "Save snapshots", source: "", configuration: .init(planner: planner, reviewers: []))
        let source = ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal, messages: [])
        state.threadStore.upsert(source.summary)
        plan.finish(.draft, text: "Initial design")
        plan.finish(.reconcile, text: "Final design")
        plan.approvedVersionID = plan.versions[0].id
        let childID = UUID().uuidString.lowercased()
        let child = ChatSession(id: childID, projectId: project.id, title: "Implement snapshots", messages: [])
        try state.threadStore.saveCodingPlan(plan, implementation: child.summary)

        let plans = try await state.codingPlanActivities(projectID: project.id)
        let summary = try XCTUnwrap(plans.first)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(summary.threadID, source.id)
        XCTAssertEqual(summary.implementationThreadID, childID)
        XCTAssertEqual(summary.currentVersionID, plan.versions.last?.id)
        XCTAssertEqual(summary.approvedVersionID, plan.versions.first?.id)
        XCTAssertEqual(summary.featureExcerpt, "Initial design")
        XCTAssertEqual(summary.planningStatus, "approved")
        XCTAssertEqual(summary.implementationStatus, "unknown")
        let alias = try await callPlanTool("ide__list_coding_plans", ["thread_id": .string(childID)])
        XCTAssertEqual(alias["plans"]?[0]?["plan_id"]?.stringValue, plan.id.uuidString)

        var task = ProjectTask(projectId: project.id, title: "Implement snapshots", status: .inProgress, sessionKey: childID)
        state.taskBoards[project.id] = TaskBoard(tasks: [task])
        let inProgress = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(inProgress.first?.implementationStatus, "in_progress")
        task.status = .done
        state.taskBoards[project.id] = TaskBoard(tasks: [task])
        let implemented = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(implemented.first?.implementationStatus, "implemented")

        state.taskBoards[project.id] = TaskBoard()
        var check = ChatSession(id: UUID().uuidString, projectId: project.id, title: "Check", messages: []).summary
        check.parentThreadId = childID
        check.threadLabel = TaskCompletionCheckLabel.unverified
        state.threadStore.upsert(check)
        let unverified = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(unverified.first?.implementationStatus, "unknown")
        check.threadLabel = TaskCompletionCheckLabel.verified
        state.threadStore.upsert(check)
        let verified = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(verified.first?.implementationStatus, "implemented")

        state.threadStore.delete(id: source.id)
        let recovered = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString)])
        XCTAssertEqual(recovered["total"]?.numberValue, 2)
        XCTAssertEqual(recovered["plan"]?["thread_id"]?.stringValue, childID)
    }

    func testPlanToolsAdvertiseReadOnlyAccessAcrossProviders() throws {
        let names = ["ide__list_coding_plans", "ide__list_coding_plan_versions", "ide__get_coding_plan_version"]
        for provider in [AgentProvider.codex, .claudeCode, .acp, .localAgent] {
            let tools = IDEToolRegistry.tools(for: provider.staticCapabilities, provider: provider)
            for name in names {
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                let hints = try XCTUnwrap(IDEMCPServer.toolDescriptor(tool)["annotations"] as? [String: Bool])
                XCTAssertEqual(hints["readOnlyHint"], true)
                XCTAssertEqual(hints["destructiveHint"], false)
            }
        }
    }

    func testPlanFeatureExcerptUsesScopeAndSkipsCodeExamples() {
        let markdown = """
        # Plugin support
        The host has finished its discussion.
        ## Objective and scope
        Load signed extensions and their contributed views.
        ```swift
        implementationDetail()
        ```
        - Register custom themes.
        ## Verification
        Build the project.
        """
        XCTAssertEqual(AppState.codingPlanExcerpt(markdown, goal: "Plugins"),
                       "Load signed extensions and their contributed views.\n- Register custom themes.")
        XCTAssertEqual(AppState.codingPlanExcerpt(nil, goal: "Plugins"), "Plugins")
    }

    func testPlanToolEmptyResultsAndInvalidSelection() async throws {
        let empty = try await callPlanTool("ide__list_coding_plans", [:])
        XCTAssertEqual(empty["plans"]?.arrayValue, [])
        let plan = CodingPlan(id: UUID(), goal: "Empty debate", source: "", configuration: .init(planner: planner, reviewers: []))
        state.threadStore.upsert(ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal, messages: []).summary)
        try state.threadStore.saveCodingPlan(plan)
        let versions = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString)])
        XCTAssertEqual(versions["versions"]?.arrayValue, [])
        let corruptID = UUID().uuidString
        state.threadStore.upsert(ChatSession(id: corruptID, projectId: project.id, title: "Damaged", messages: []).summary)
        let corrupt = try XCTUnwrap(state.threadStore.fetch(id: corruptID))
        corrupt.codingPlanData = Data([0])
        try state.threadStore.context.save()
        let recovered = try await callPlanTool("ide__list_coding_plans", [:])
        XCTAssertEqual(recovered["total"]?.numberValue, 1)
        do {
            _ = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(corruptID)])
            XCTFail("Targeted reads must report corrupt history.")
        } catch IDEToolError.handlerFailed { }

        let invalid: [(String, [String: JSONValue])] = [
            ("ide__list_coding_plan_versions", ["plan_id": .string(UUID().uuidString)]),
            ("ide__get_coding_plan_version", ["plan_id": .string(plan.id.uuidString), "version_id": .string(UUID().uuidString)]),
            ("ide__list_coding_plans", ["project_id": .string("typo")]),
            ("ide__list_coding_plans", ["limit": .number(51)]),
        ]
        for (name, arguments) in invalid {
            do {
                _ = try await callPlanTool(name, arguments)
                XCTFail("Expected invalid arguments for \(name)")
            } catch IDEToolError.invalidArguments { }
        }
    }
}
