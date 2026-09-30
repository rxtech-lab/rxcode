import XCTest
import RxCodeCore
@testable import RxCode

/// Covers the board's column triggers: `TaskBoardHook` moving the task whose
/// thread just stopped or was reviewed, the redirect-aware session matching
/// underneath it, and column management.
///
/// Wired to the real `AppStateHookController` (as `PlanModeHookSuppressionTests`
/// is) so the seam between hook and `AppState` is exercised rather than mocked.
/// Persistence is injected so no board is written to Application Support.
@MainActor
final class TaskBoardHookTests: XCTestCase {

    private var persistence: MockAppStatePersistence!
    private var appState: AppState!
    private var hook: TaskBoardHook!
    private var project: Project!
    private var retryDelay: TimeInterval!

    override func setUp() async throws {
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
        hook = TaskBoardHook()
        project = Project(name: "P", path: "/tmp/p", gitHubRepo: nil)
        appState.projects = [project]
        // No agent can be spawned here, so every completion check fails and is
        // retried — without this the hook tests would sit out the backoff.
        retryDelay = AppState.taskCompletionCheckRetryDelay
        AppState.taskCompletionCheckRetryDelay = 0
    }

    override func tearDown() async throws {
        AppState.taskCompletionCheckRetryDelay = retryDelay
        persistence = nil
        appState = nil
        hook = nil
        project = nil
        retryDelay = nil
    }

    // MARK: - Helpers

    private func seed(_ tasks: [ProjectTask]) {
        appState.taskBoards[project.id] = TaskBoard(tasks: tasks)
    }

    private func makeTask(
        status: TaskStatus = .inProgress,
        sessionKey: String? = "sess-1"
    ) -> ProjectTask {
        ProjectTask(
            projectId: project.id,
            title: "Wire the board",
            status: status,
            agent: TaskAgentConfig(provider: .claudeCode, model: "opus"),
            sessionKey: sessionKey,
            sortIndex: 1
        )
    }

    private func payload(
        sessionKey: String = "sess-1",
        reason: SessionEndReason = .completed,
        turnDidError: Bool = false,
        hasQueuedFollowups: Bool = false
    ) -> SessionEndPayload {
        SessionEndPayload(
            project: project,
            sessionKey: sessionKey,
            sessionId: sessionKey,
            reason: reason,
            turnDidError: turnDidError,
            lastAssistantText: "done",
            hasQueuedFollowups: hasQueuedFollowups
        )
    }

    private func status(of id: UUID) -> TaskStatus? {
        appState.task(id: id)?.status
    }

    // MARK: - Chat dispatch

    func testCreatingAssignedTaskInChatColumnDispatches() {
        let task = makeTask(sessionKey: nil)

        XCTAssertTrue(appState.shouldDispatchTask(task, from: nil))
        XCTAssertFalse(appState.shouldDispatchTask(task, from: .inProgress), "editing in the same chat column must not start another thread")
    }

    func testEnteringChatColumnDispatchesButOtherTasksDoNot() {
        let task = makeTask(sessionKey: nil)
        XCTAssertTrue(appState.shouldDispatchTask(task, from: .pending))

        var unassigned = task
        unassigned.agent = TaskAgentConfig()
        XCTAssertFalse(appState.shouldDispatchTask(unassigned, from: nil))

        var pending = task
        pending.status = .pending
        XCTAssertFalse(appState.shouldDispatchTask(pending, from: nil))
    }

    // MARK: - Session-stop trigger

    func testAdvancesLinkedInProgressTask() {
        let task = makeTask()
        seed([task])

        XCTAssertEqual(appState.applyTaskTrigger(.sessionStop, sessionKey: "sess-1"), task.id)
        XCTAssertEqual(status(of: task.id), .pendingReview)
    }

    func testIgnoresUnrelatedSession() {
        let task = makeTask()
        seed([task])

        XCTAssertNil(appState.applyTaskTrigger(.sessionStop, sessionKey: "other-session"))
        XCTAssertEqual(status(of: task.id), .inProgress)
    }

    func testIgnoresColumnWithoutSessionStopTarget() {
        // A task the user already dragged to Done must not be dragged back to
        // review by a late turn completion on its old thread.
        let task = makeTask(status: .done)
        seed([task])

        XCTAssertNil(appState.applyTaskTrigger(.sessionStop, sessionKey: "sess-1"))
        XCTAssertEqual(status(of: task.id), .done)
    }

    func testIgnoresTaskWithNoLinkedThread() {
        let task = makeTask(sessionKey: nil)
        seed([task])

        XCTAssertNil(appState.applyTaskTrigger(.sessionStop, sessionKey: "sess-1"))
        XCTAssertEqual(status(of: task.id), .inProgress)
    }

    /// The CLI rotates the session id mid-life (`pending-<uuid>` → real sid),
    /// so the key recorded at dispatch will not raw-match the finishing turn's.
    func testMatchesThroughSessionIdRedirect() {
        let task = makeTask(sessionKey: "pending-abc")
        seed([task])
        appState.sessionIdRedirect["pending-abc"] = "real-sid"

        XCTAssertEqual(appState.applyTaskTrigger(.sessionStop, sessionKey: "real-sid"), task.id)
        XCTAssertEqual(status(of: task.id), .pendingReview)
    }

    func testAdvancedTaskMovesToEndOfReviewColumn() {
        let existing = ProjectTask(
            projectId: project.id,
            title: "already in review",
            status: .pendingReview,
            sortIndex: 5
        )
        let task = makeTask()
        seed([existing, task])

        appState.applyTaskTrigger(.sessionStop, sessionKey: "sess-1")

        let column = appState.tasks(in: .pendingReview, projectFilter: project.id)
        XCTAssertEqual(column.map(\.title), ["already in review", "Wire the board"])
    }

    // MARK: - Hook gating

    func testHookFlagsTaskWhenCompletionCannotBeVerified() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(payload(), controller: appState.hookController)

        XCTAssertEqual(outcome.control, .proceed)
        XCTAssertEqual(status(of: task.id), .pending)
        XCTAssertNotNil(appState.task(id: task.id)?.attentionReason)
    }

    /// A stopped run must leave the locked chat column, but an unfinished turn
    /// cannot enter Pending Review.
    func testHookFlagsCancelledTurn() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(
            payload(reason: .cancelled), controller: appState.hookController
        )

        XCTAssertEqual(outcome.control, .proceed)
        XCTAssertEqual(status(of: task.id), .pending)
        XCTAssertNotNil(appState.task(id: task.id)?.attentionReason)
    }

    func testHookFlagsErroredTurn() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(
            payload(turnDidError: true), controller: appState.hookController
        )

        XCTAssertEqual(outcome.control, .proceed)
        XCTAssertEqual(status(of: task.id), .pending)
        XCTAssertNotNil(appState.task(id: task.id)?.attentionReason)
    }

    /// Continuing a rejected task's chat directly (not through the task board)
    /// must put the card back in the chat column while the agent works.
    func testResumedChatMovesRejectedTaskBackToChatColumn() async {
        let task = makeTask(sessionKey: "pending-abc")
        seed([task])
        appState.sessionIdRedirect["pending-abc"] = "real-sid"
        _ = await hook.afterSessionEnd(payload(sessionKey: "real-sid"), controller: appState.hookController)
        XCTAssertEqual(status(of: task.id), .pending)

        appState.resumeTaskForStreamingSession("real-sid")

        XCTAssertEqual(status(of: task.id), .inProgress)
        XCTAssertNil(appState.task(id: task.id)?.attentionReason)
    }

    func testResumedChatIgnoresUnlinkedSessionAndChatColumnTasks() {
        let pending = makeTask(status: .pending, sessionKey: "sess-1")
        let running = makeTask(status: .inProgress, sessionKey: "sess-2")
        seed([pending, running])
        let runningSortIndex = appState.task(id: running.id)?.sortIndex

        appState.resumeTaskForStreamingSession("other-session")
        appState.resumeTaskForStreamingSession("sess-2")

        XCTAssertEqual(status(of: pending.id), .pending)
        XCTAssertEqual(appState.task(id: running.id)?.sortIndex, runningSortIndex)
    }

    /// A run cut short by quitting the app never reports a session end, so
    /// loading boards releases it.
    func testInterruptedRunsNeedAttentionOnLoad() {
        let running = makeTask()
        let manual = ProjectTask(projectId: running.projectId, title: "No agent", status: .inProgress)
        seed([running, manual])

        appState.releaseInterruptedTasks()

        XCTAssertEqual(status(of: running.id), .pending)
        XCTAssertNotNil(appState.task(id: running.id)?.attentionReason)
        XCTAssertEqual(status(of: manual.id), .inProgress)
    }

    func testAttentionFlagSurvivesBoardEncodingAndAllowsManualMove() throws {
        var task = makeTask()
        task.attentionReason = "One requested change is missing."
        let restored = try JSONDecoder().decode(ProjectTask.self, from: JSONEncoder().encode(task))
        seed([restored])

        XCTAssertEqual(restored.attentionReason, task.attentionReason)
        XCTAssertFalse(appState.isStatusLocked(restored))
        appState.moveTask(restored, to: .pending)
        XCTAssertEqual(status(of: task.id), .pending)
    }

    func testCompletionVerdictRequiresFinalExplicitMarker() {
        XCTAssertEqual(AppState.taskCompletionVerdict(from: "Checks passed.\nTASK_RESULT: COMPLETE"), true)
        XCTAssertEqual(AppState.taskCompletionVerdict(from: "One item is missing.\nTASK_RESULT: INCOMPLETE"), false)
        XCTAssertNil(AppState.taskCompletionVerdict(from: "TASK_RESULT: COMPLETE\nOne item is still missing."))
        XCTAssertNil(AppState.taskCompletionVerdict(from: "Looks done."))
    }

    func testCompletionExplanationAndRetryPromptKeepFullError() {
        let explanation = String(repeating: "The requested check still fails. ", count: 20)
            + "\n\nThe missing change is in TaskCardView."
        let response = explanation + "\nTASK_RESULT: INCOMPLETE\n"
        XCTAssertEqual(AppState.taskCompletionExplanation(from: response), explanation)

        var task = makeTask()
        task.attentionReason = explanation
        let prompt = task.agentPrompt(storyTitle: nil)
        XCTAssertTrue(prompt.contains(explanation))
        XCTAssertTrue(task.checkErrorFixPrompt?.contains(explanation) == true)
        XCTAssertEqual(TaskPromptContent.task(in: prompt)?.title, task.title)
    }

    /// The retry policy: a check that never returned a verdict is worth running
    /// again, while an explicit COMPLETE/INCOMPLETE is the checker's answer and
    /// is taken as it stands. (`testHookFlagsTaskWhenCompletionCannotBeVerified`
    /// covers the task being flagged once the attempts are exhausted.)
    func testOnlyFailedCompletionChecksAreRetried() {
        func checkResult(_ text: String, error: String? = nil) -> HookLinkedThreadResult {
            HookLinkedThreadResult(threadId: "check-1", assistantText: text, error: error)
        }

        XCTAssertEqual(AppState.taskCompletionCheckMaxAttempts, 3)
        // Thread could not be sent, the agent errored, it timed out with no
        // text, and it answered without the marker.
        XCTAssertEqual(AppState.taskCompletionOutcome(from: nil), .failed(reason: nil))
        XCTAssertEqual(
            AppState.taskCompletionOutcome(from: checkResult("", error: "stream failed")),
            .failed(reason: "stream failed")
        )
        XCTAssertEqual(AppState.taskCompletionOutcome(from: checkResult("")), .failed(reason: nil))
        XCTAssertEqual(
            AppState.taskCompletionOutcome(from: checkResult("Looks done to me.")),
            .failed(reason: "Looks done to me.")
        )

        XCTAssertEqual(
            AppState.taskCompletionOutcome(from: checkResult("Checks passed.\nTASK_RESULT: COMPLETE")),
            .verdict(true, explanation: "Checks passed.")
        )
        XCTAssertEqual(
            AppState.taskCompletionOutcome(from: checkResult("One item is missing.\nTASK_RESULT: INCOMPLETE")),
            .verdict(false, explanation: "One item is missing.")
        )
    }

    // MARK: - Completion check status

    private func checkThread(id: String, label: String?) -> ChatSession.Summary {
        ChatSession.Summary(
            id: id,
            projectId: project.id,
            title: "Task Completion Check",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: false,
            parentThreadId: "sess-1",
            threadLabel: label
        )
    }

    /// The in-progress label alone never means "still verifying": a check whose
    /// verdict never landed keeps it, so the chip follows the live stream.
    func testCheckThreadStopsVerifyingOnceItsRunEnds() {
        let summary = checkThread(id: "check-1", label: AppState.taskCompletionCheckLabel)

        XCTAssertEqual(appState.taskCompletionCheckState(for: summary), .unverified)

        var streaming = SessionStreamState()
        streaming.isStreaming = true
        appState.sessionStates["check-1"] = streaming
        XCTAssertEqual(appState.taskCompletionCheckState(for: summary), .verifying)

        appState.sessionStates["check-1"]?.isStreaming = false
        XCTAssertEqual(appState.taskCompletionCheckState(for: summary), .unverified)

        XCTAssertEqual(
            appState.taskCompletionCheckState(for: checkThread(id: "check-2", label: AppState.taskCompletionVerifiedLabel)),
            .verified
        )
        XCTAssertNil(appState.taskCompletionCheckState(for: checkThread(id: "check-3", label: "Code Review")))
    }

    /// The verdict has to land on the thread's *current* id — the CLI may have
    /// renamed the session (and with it the store row) after the spawn returned
    /// the key it knew.
    func testCompletionVerdictLabelsTheRenamedCheckThread() {
        let pendingKey = "pending-check"
        let realId = "check-real"
        appState.threadStore = ThreadStore.inMemory()
        appState.allSessionSummaries = [checkThread(id: realId, label: AppState.taskCompletionCheckLabel)]
        appState.threadStore.upsert(appState.allSessionSummaries[0])
        appState.applySessionIdRedirect(from: pendingKey, to: realId)

        appState.setTaskCompletionLabel(pendingKey, parentThreadId: "sess-1", verified: true)

        XCTAssertEqual(appState.allSessionSummaries[0].threadLabel, AppState.taskCompletionVerifiedLabel)
        XCTAssertEqual(appState.threadStore.fetch(id: realId)?.threadLabel, AppState.taskCompletionVerifiedLabel)
    }

    /// A check that outlived the spawn's wait was labelled from partial text;
    /// its run finishing with a verdict has to correct the label.
    func testLateCompletionCheckVerdictRelabelsTheThread() {
        appState.threadStore = ThreadStore.inMemory()
        appState.allSessionSummaries = [
            checkThread(id: "check-late", label: AppState.taskCompletionUnverifiedLabel),
            checkThread(id: "chat", label: nil)
        ]
        for summary in appState.allSessionSummaries { appState.threadStore.upsert(summary) }

        appState.reconcileTaskCompletionLabel(sessionId: "check-late", assistantText: "Still checking…")
        XCTAssertEqual(appState.allSessionSummaries[0].threadLabel, AppState.taskCompletionUnverifiedLabel)

        appState.reconcileTaskCompletionLabel(sessionId: "check-late", assistantText: "All done.\nTASK_RESULT: COMPLETE")
        XCTAssertEqual(appState.allSessionSummaries[0].threadLabel, AppState.taskCompletionVerifiedLabel)
        XCTAssertEqual(appState.threadStore.fetch(id: "check-late")?.threadLabel, AppState.taskCompletionVerifiedLabel)

        appState.reconcileTaskCompletionLabel(sessionId: "chat", assistantText: "TASK_RESULT: COMPLETE")
        XCTAssertNil(appState.allSessionSummaries[1].threadLabel)
    }

    /// A check interrupted by quitting the app has no run left to finish it, so
    /// loading the store settles it rather than leaving a perpetual "Verifying".
    func testInterruptedCompletionChecksAreFinalizedOnLoad() {
        let store = ThreadStore.inMemory()
        let running = checkThread(id: "check-running", label: AppState.taskCompletionCheckLabel)
        let decided = checkThread(id: "check-decided", label: AppState.taskCompletionVerifiedLabel)
        let review = checkThread(id: "review", label: AppState.manualCodeReviewLabel)
        for summary in [running, decided, review] { store.upsert(summary) }

        XCTAssertEqual(store.finalizeInterruptedCompletionChecks(), [running.id])

        XCTAssertEqual(store.fetch(id: running.id)?.threadLabel, AppState.taskCompletionUnverifiedLabel)
        XCTAssertEqual(store.fetch(id: decided.id)?.threadLabel, AppState.taskCompletionVerifiedLabel)
        XCTAssertEqual(store.fetch(id: review.id)?.threadLabel, AppState.manualCodeReviewLabel)
    }

    func testChatAgentCanCreateStoryAndTaskInIt() async throws {
        let projectArg = JSONValue.string(project.id.uuidString)
        _ = try await appState.ideHandleToolCall(
            name: "ide__create_story",
            arguments: .object(["project_id": projectArg, "title": .string("Dashboard work")]),
            sessionKey: "chat-1"
        )
        let story = try XCTUnwrap(appState.stories(projectFilter: project.id).first)

        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": projectArg,
                "story_id": .string(story.id.uuidString),
                "title": .string("Add task tool"),
                "details": .string("Agents can create tasks from chat.")
            ]),
            sessionKey: "chat-1"
        )

        let task = try XCTUnwrap(appState.allTasks(projectFilter: project.id).first)
        XCTAssertEqual(task.storyId, story.id)
        XCTAssertEqual(task.sourceSessionKey, "chat-1")
        XCTAssertEqual(task.status, .backlog)

        do {
            _ = try await appState.ideHandleToolCall(
                name: "ide__create_task",
                arguments: .object([
                    "project_id": projectArg,
                    "story_id": .string(UUID().uuidString),
                    "title": .string("Wrong story")
                ]),
                sessionKey: "chat-1"
            )
            XCTFail("A task cannot link to a story from another project or an unknown story")
        } catch {
            XCTAssertEqual(appState.allTasks(projectFilter: project.id).count, 1)
        }
    }

    /// A task created from a chat that is still running joins that run in
    /// In Progress instead of starting the chat again, and leaves with it.
    func testTaskFromRunningChatAdoptsTheRunWithoutDispatching() {
        var task = makeTask(status: .backlog, sessionKey: nil)
        task.sourceSessionKey = "chat-1"
        seed([task])
        appState.sessionActivity["chat-1"] = SessionActivity(isStreaming: true)

        appState.adoptRunningChat("chat-1", forTask: task.id)

        let adopted = appState.task(id: task.id)
        XCTAssertEqual(adopted?.status, .inProgress)
        XCTAssertEqual(adopted?.sessionKey, "chat-1")
        XCTAssertTrue(appState.dispatchingTaskIds.isEmpty)
        XCTAssertFalse(appState.shouldDispatchTask(adopted!, from: adopted!.status))

        appState.sessionActivity["chat-1"] = SessionActivity(isStreaming: false)
        XCTAssertNotNil(appState.applyTaskTrigger(.sessionStop, sessionKey: "chat-1"))
        XCTAssertEqual(appState.task(id: task.id)?.status, .pendingReview)
    }

    func testTaskFromIdleChatStaysInItsColumn() {
        var task = makeTask(status: .backlog, sessionKey: nil)
        task.sourceSessionKey = "chat-1"
        seed([task])

        appState.adoptRunningChat("chat-1", forTask: task.id)

        XCTAssertEqual(appState.task(id: task.id)?.status, .backlog)
        XCTAssertNil(appState.task(id: task.id)?.sessionKey)
    }

    func testChatAgentReusesCompletedTaskWhenRecordingSameWorkAgain() async throws {
        let story = ProjectStory(projectId: project.id, title: "Dashboard work")
        let completed = ProjectTask(
            projectId: project.id,
            storyId: story.id,
            title: "Add colored provider icons",
            details: "Show colored provider icons on task cards.",
            status: .done,
            sessionKey: "completed-thread"
        )
        appState.taskBoards[project.id] = TaskBoard(stories: [story], tasks: [completed])

        let result = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "title": .string(completed.title),
                "details": .string(completed.details),
            ]),
            sessionKey: "follow-up-thread"
        )

        XCTAssertEqual(appState.allTasks(projectFilter: project.id).map(\.id), [completed.id])
        XCTAssertEqual(appState.task(id: completed.id)?.status, .done)
        let resultText = try XCTUnwrap(toolResultText(result))
        XCTAssertTrue(resultText.contains(completed.id.uuidString))
        XCTAssertTrue(resultText.contains("already_exists"))
    }

    func testChatAgentReusesCompletedTaskWhenItsThreadRephrasesTheWork() async throws {
        let completed = ProjectTask(
            projectId: project.id,
            title: "Add colored provider icons",
            details: "Show colored provider icons on task cards.",
            status: .done,
            sessionKey: "completed-thread"
        )
        appState.taskBoards[project.id] = TaskBoard(tasks: [completed])

        let result = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "title": .string("Fix provider artwork after review"),
                "details": .string("Adjust the task card logos based on the latest feedback."),
            ]),
            sessionKey: "completed-thread"
        )

        XCTAssertEqual(appState.allTasks(projectFilter: project.id).map(\.id), [completed.id])
        XCTAssertEqual(appState.task(id: completed.id)?.status, .done)
        let resultText = try XCTUnwrap(toolResultText(result))
        XCTAssertTrue(resultText.contains(completed.id.uuidString))
        XCTAssertTrue(resultText.contains("already_exists"))
    }

    func testParentInAnotherProjectStartsDependentAndDeletionClearsLink() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        appState.projects = [project, other]
        var parent = ProjectTask(projectId: project.id, title: "API", status: .pending)
        appState.taskBoards[project.id] = TaskBoard(tasks: [parent])
        appState.taskBoards[other.id] = TaskBoard()

        let result = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(other.id.uuidString),
                "title": .string("Client"),
                "details": .string("Call the new API"),
                "starts_after_task_id": .string(parent.id.uuidString),
            ]),
            sessionKey: "chat-1"
        )
        XCTAssertTrue(try XCTUnwrap(toolResultText(result)).contains(parent.id.uuidString))
        let child = try XCTUnwrap(appState.taskBoard(for: other.id).tasks.first)
        XCTAssertEqual(child.parentTaskId, parent.id)
        XCTAssertFalse(appState.canLinkTask(parent.id, to: child.id))
        XCTAssertEqual(
            appState.parentTaskChoices(for: parent.id, in: project.id).flatMap { $0.groups.flatMap(\.tasks) }.map(\.id),
            []
        )

        parent.status = .pendingReview
        appState.upsertTask(parent)
        XCTAssertEqual(appState.task(id: child.id)?.status, .inProgress)

        appState.deleteTask(parent)
        XCTAssertNil(appState.task(id: child.id)?.parentTaskId)
    }

    func testIDECreateTaskWaitsForAllParentsAcrossProjects() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        appState.projects = [project, other]
        var first = ProjectTask(projectId: project.id, title: "API", status: .pending)
        var second = ProjectTask(projectId: other.id, title: "Design", status: .pending)
        appState.taskBoards[project.id] = TaskBoard(tasks: [first])
        appState.taskBoards[other.id] = TaskBoard(tasks: [second])

        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(other.id.uuidString),
                "title": .string("Client"),
                "starts_after_task_ids": .array([.string(first.id.uuidString), .string(second.id.uuidString)]),
            ]),
            sessionKey: "multi-parent-chat"
        )
        let child = try XCTUnwrap(appState.taskBoard(for: other.id).tasks.first { $0.title == "Client" })
        XCTAssertEqual(child.parentTaskIds, [first.id, second.id])

        first.status = .pendingReview
        appState.upsertTask(first)
        XCTAssertEqual(appState.task(id: child.id)?.status, .backlog)

        second.status = .pendingReview
        appState.upsertTask(second)
        XCTAssertEqual(appState.task(id: child.id)?.status, .inProgress)
    }

    func testChatAgentCanShareStoryAcrossProjectsAndTrackTasks() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        appState.projects = [project, other]
        appState.taskBoards[project.id] = TaskBoard()
        appState.taskBoards[other.id] = TaskBoard()

        _ = try await appState.ideHandleToolCall(
            name: "ide__create_story",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "title": .string("Cross-project work"),
                "linked_project_ids": .array([.string(other.id.uuidString)]),
            ]),
            sessionKey: "chat-1"
        )
        let story = try XCTUnwrap(appState.stories(projectFilter: project.id).first)
        let mirror = try XCTUnwrap(appState.taskBoard(for: other.id).story(id: story.id))
        XCTAssertEqual(mirror.projectId, other.id)
        XCTAssertEqual(mirror.linkedProjectIds, [project.id])
        XCTAssertEqual(story.linkedProjectIds, [other.id])

        // A task in the linked project can join the shared story.
        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(other.id.uuidString),
                "story_id": .string(story.id.uuidString),
                "title": .string("Backend half"),
            ]),
            sessionKey: "chat-1"
        )
        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "story_id": .string(story.id.uuidString),
                "title": .string("Frontend half"),
            ]),
            sessionKey: "chat-1"
        )

        // Editing one copy updates the other, and keeps the links.
        var renamed = mirror
        renamed.title = "Renamed"
        renamed.linkedProjectIds = []
        appState.upsertStory(renamed)
        XCTAssertEqual(appState.taskBoard(for: project.id).story(id: story.id)?.title, "Renamed")
        XCTAssertEqual(appState.taskBoard(for: other.id).story(id: story.id)?.linkedProjectIds, [project.id])

        let listed = try await appState.ideHandleToolCall(
            name: "ide__get_tasks",
            arguments: .object(["story_id": .string(story.id.uuidString)]),
            sessionKey: "chat-1"
        )
        let listedText = try XCTUnwrap(toolResultText(listed))
        XCTAssertTrue(listedText.contains("Backend half"))
        XCTAssertTrue(listedText.contains("Frontend half"))

        let backend = try XCTUnwrap(appState.allTasks(projectFilter: other.id).first)
        let status = try await appState.ideHandleToolCall(
            name: "ide__get_task_status",
            arguments: .object(["task_id": .string(backend.id.uuidString)]),
            sessionKey: "chat-1"
        )
        let statusText = try XCTUnwrap(toolResultText(status))
        XCTAssertTrue(statusText.contains("\"is_running\":false") || statusText.contains("\"is_running\" : false"))

        // Unlinking removes the copy and orphans that project's tasks.
        _ = try await appState.ideHandleToolCall(
            name: "ide__link_story",
            arguments: .object([
                "story_id": .string(story.id.uuidString),
                "unlink_project_ids": .array([.string(other.id.uuidString)]),
            ]),
            sessionKey: "chat-1"
        )
        XCTAssertNil(appState.taskBoard(for: other.id).story(id: story.id))
        XCTAssertNil(appState.task(id: backend.id)?.storyId)
        XCTAssertEqual(appState.taskBoard(for: project.id).story(id: story.id)?.linkedProjectIds, [])
    }

    /// The first text block of an IDE tool result. Matched by case because the
    /// app target redeclares `JSONValue`'s accessors, which makes them ambiguous
    /// under `@testable import`.
    private func toolResultText(_ result: JSONValue) -> String? {
        guard case .array(let blocks)? = result["content"],
              case .string(let text)? = blocks.first?["text"]
        else { return nil }
        return text
    }

    /// The story form edits links on the draft; saving applies the difference.
    func testSaveStoryAppliesFormLinkChanges() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        let third = Project(name: "R", path: "/tmp/r", gitHubRepo: nil)
        appState.projects = [project, other, third]
        for id in [project.id, other.id, third.id] { appState.taskBoards[id] = TaskBoard() }

        let story = ProjectStory(projectId: project.id, title: "Shared", linkedProjectIds: [other.id])
        await appState.saveStory(story)
        XCTAssertEqual(appState.taskBoard(for: other.id).story(id: story.id)?.linkedProjectIds, [project.id])

        let task = ProjectTask(projectId: other.id, storyId: story.id, title: "Other half")
        appState.upsertTask(task)
        XCTAssertEqual(appState.tasks(inStory: story).map(\.id), [task.id])
        XCTAssertEqual(appState.stories().filter { $0.id == story.id }.count, 1)

        var edited = try XCTUnwrap(appState.taskBoard(for: project.id).story(id: story.id))
        edited.linkedProjectIds = [third.id]
        await appState.saveStory(edited)
        XCTAssertNil(appState.taskBoard(for: other.id).story(id: story.id))
        XCTAssertNil(appState.task(id: task.id)?.storyId)
        XCTAssertEqual(appState.taskBoard(for: third.id).story(id: story.id)?.linkedProjectIds, [project.id])
        XCTAssertEqual(appState.taskBoard(for: project.id).story(id: story.id)?.linkedProjectIds, [third.id])
    }

    /// A thread with messages still queued hasn't finished its work, so the task
    /// stays In Progress until the queue drains.
    func testHookDefersWhileFollowupsAreQueued() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(
            payload(hasQueuedFollowups: true), controller: appState.hookController
        )

        XCTAssertEqual(outcome.control, .ignored)
        XCTAssertEqual(status(of: task.id), .inProgress)
    }

    func testHookIgnoresThreadThatOwnsNoTask() async {
        seed([])

        let outcome = await hook.afterSessionEnd(payload(), controller: appState.hookController)

        XCTAssertEqual(outcome.control, .ignored)
    }

    // MARK: - Custom columns

    private static let qa: TaskStatus = "qa"

    /// Backlog → In Progress (chat) → QA, where a review routes the card to
    /// Done on pass and back to In Progress on fail.
    private func seedCustomColumns(_ tasks: [ProjectTask]) {
        var columns = TaskColumn.defaults.filter { $0.id != .pendingReview }
        let inProgress = columns.firstIndex { $0.id == .inProgress }!
        columns[inProgress].onSessionStop = Self.qa
        columns.insert(
            TaskColumn(id: Self.qa, name: "QA", onReviewPass: .done, onReviewFail: .inProgress),
            at: inProgress + 1
        )
        appState.taskBoards[project.id] = TaskBoard(tasks: tasks, columns: columns)
    }

    private func reviewPayload(passed: Bool?, fixTurnStarted: Bool = false) -> ReviewEventPayload {
        ReviewEventPayload(
            project: project,
            sessionKey: "sess-1",
            sessionId: "sess-1",
            passed: passed,
            fixTurnStarted: fixTurnStarted
        )
    }

    func testSessionStopFollowsCustomColumnTarget() async {
        let task = makeTask()
        seedCustomColumns([task])

        _ = await hook.afterSessionEnd(payload(), controller: appState.hookController)

        XCTAssertEqual(status(of: task.id), Self.qa)
    }

    func testReviewPassAndFailFollowColumnTargets() async {
        let task = makeTask(status: Self.qa)
        seedCustomColumns([task])

        _ = await hook.onReviewStop(reviewPayload(passed: false, fixTurnStarted: true), controller: appState.hookController)
        XCTAssertEqual(status(of: task.id), .inProgress)

        _ = await hook.afterSessionEnd(payload(), controller: appState.hookController)
        XCTAssertEqual(status(of: task.id), Self.qa)

        _ = await hook.onReviewStop(reviewPayload(passed: true), controller: appState.hookController)
        XCTAssertEqual(status(of: task.id), .done)
    }

    /// Without a fix turn the thread won't stop again, so routing the card into
    /// a chat column would leave it locked there.
    func testReviewFailWithoutFixTurnDoesNotEnterChatColumn() async {
        let task = makeTask(status: Self.qa)
        seedCustomColumns([task])

        let outcome = await hook.onReviewStop(reviewPayload(passed: false), controller: appState.hookController)

        XCTAssertEqual(outcome.control, .ignored)
        XCTAssertEqual(status(of: task.id), Self.qa)
    }

    func testReviewWithoutVerdictLeavesCardAlone() async {
        let task = makeTask(status: Self.qa)
        seedCustomColumns([task])

        _ = await hook.onReviewStop(reviewPayload(passed: nil), controller: appState.hookController)

        XCTAssertEqual(status(of: task.id), Self.qa)
    }

    func testReviewStartFollowsColumnTarget() async {
        let task = makeTask(status: .pendingReview)
        var columns = TaskColumn.defaults
        let review = columns.firstIndex { $0.id == .pendingReview }!
        columns[review].onReviewStart = .pending
        appState.taskBoards[project.id] = TaskBoard(tasks: [task], columns: columns)

        _ = await hook.onReviewStart(reviewPayload(passed: nil), controller: appState.hookController)

        XCTAssertEqual(status(of: task.id), .pending)
    }

    func testColumnWithoutTriggerLeavesCardAlone() async {
        let task = makeTask(status: .backlog)
        seed([task])

        let outcome = await hook.afterSessionEnd(payload(), controller: appState.hookController)

        XCTAssertEqual(outcome.control, .ignored)
        XCTAssertEqual(status(of: task.id), .backlog)
    }

    func testCustomChatColumnLocksDispatchedTask() {
        var columns = TaskColumn.defaults
        columns.append(TaskColumn(id: "agent", name: "Agent", triggersChat: true, onSessionStop: .done))
        let task = makeTask(status: "agent")
        appState.taskBoards[project.id] = TaskBoard(tasks: [task], columns: columns)

        XCTAssertTrue(appState.isStatusLocked(task))
        appState.moveTask(task, to: .backlog)
        XCTAssertEqual(status(of: task.id), "agent")
    }

    func testInterruptedRunUsesSessionStopTarget() {
        let task = makeTask()
        seedCustomColumns([task])

        appState.releaseInterruptedTasks()

        XCTAssertEqual(status(of: task.id), Self.qa)
    }

    func testDeletingColumnMovesTasksAndRepointsTriggers() {
        let task = makeTask(status: Self.qa, sessionKey: nil)
        seedCustomColumns([task])
        let qa = appState.taskBoard(for: project.id).column(for: Self.qa)

        appState.deleteColumn(qa, projectId: project.id, moveTasksTo: .done)

        let board = appState.taskBoard(for: project.id)
        XCTAssertFalse(board.effectiveColumns.contains { $0.id == Self.qa })
        XCTAssertEqual(status(of: task.id), .done)
        XCTAssertEqual(board.column(for: .inProgress).onSessionStop, .done)
    }

    // MARK: - Run turns

    /// The Run tab pairs each prompt with the agent's *final* text for it;
    /// narration between tool calls is dropped.
    func testRunTurnsPairPromptsWithFinalResponses() {
        let messages = [
            ChatMessage(role: .user, content: "**Task:** Translate"),
            ChatMessage(role: .assistant, content: "Looking at the catalog…"),
            ChatMessage(role: .assistant, content: ""),
            ChatMessage(role: .assistant, content: "Translated 12 strings."),
            ChatMessage(role: .user, content: "Also do Japanese"),
            ChatMessage(role: .assistant, content: "Failed", isError: true),
        ]

        let turns = TaskRunTurn.turns(from: messages)

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].prompt, "**Task:** Translate")
        XCTAssertEqual(turns[0].response, "Translated 12 strings.")
        XCTAssertFalse(turns[0].didError)
        XCTAssertEqual(turns[1].prompt, "Also do Japanese")
        XCTAssertEqual(turns[1].response, "")
        XCTAssertTrue(turns[1].didError)
    }

    // MARK: - Scheduled task tool

    /// Starts an `ide__create_scheduled_task` call and waits until its
    /// proposal is queued for confirmation.
    private func proposeScheduledTask(_ arguments: [String: JSONValue]) async throws -> (Task<JSONValue, Error>, ScheduledTask) {
        let call = Task { @MainActor in
            try await appState.ideHandleToolCall(
                name: "ide__create_scheduled_task",
                arguments: .object(arguments),
                sessionKey: "chat-1"
            )
        }
        for _ in 0..<100 where appState.scheduledTaskProposals.isEmpty {
            await Task.yield()
        }
        return (call, try XCTUnwrap(appState.scheduledTaskProposals.first))
    }

    private func resultText(_ result: JSONValue) -> String {
        guard case .array(let content)? = result["content"],
              case .string(let text)? = content.first?["text"]
        else { return "" }
        return text
    }

    func testScheduledTaskToolAddsTaskOnlyAfterConfirmation() async throws {
        let (call, proposal) = try await proposeScheduledTask([
            "project_id": .string(project.id.uuidString),
            "name": .string("Dependency check"),
            "prompt": .string("Check for outdated dependencies."),
            "cron_expression": .string("0 9 * * 1-5"),
        ])
        XCTAssertEqual(proposal.projectId, project.id)
        XCTAssertEqual(proposal.cronExpression, "0 9 * * 1-5")
        XCTAssertTrue(appState.scheduledTasks.isEmpty, "Nothing is added before the user confirms")

        var edited = proposal
        edited.name = "Weekday dependency check"
        appState.resolveScheduledTaskProposal(id: proposal.id, with: edited)

        let text = resultText(try await call.value)
        XCTAssertTrue(text.contains("\"added\" : true"), text)
        XCTAssertEqual(appState.scheduledTasks.map(\.name), ["Weekday dependency check"])
        XCTAssertTrue(appState.scheduledTaskProposals.isEmpty)
    }

    func testScheduledTaskToolReportsCancellation() async throws {
        let (call, proposal) = try await proposeScheduledTask([
            "project_id": .string(project.id.uuidString),
            "name": .string("Nightly build"),
            "prompt": .string("Run the build."),
            "cron_expression": .string("@daily"),
        ])
        appState.resolveScheduledTaskProposal(id: proposal.id, with: nil)
        // A second settle, as the sheet's onDisappear does, is a no-op.
        appState.resolveScheduledTaskProposal(id: proposal.id, with: proposal)

        let text = resultText(try await call.value)
        XCTAssertTrue(text.contains("\"added\" : false"), text)
        XCTAssertTrue(appState.scheduledTasks.isEmpty)
        XCTAssertTrue(appState.scheduledTaskProposals.isEmpty)
    }

    func testScheduledTaskToolProposesNoProjectOutsideProjectChats() async throws {
        let (call, proposal) = try await proposeScheduledTask([
            "name": .string("Morning summary"),
            "prompt": .string("Summarize my day."),
            "cron_expression": .string("0 9 * * *"),
        ])
        XCTAssertNil(proposal.projectId, "An unsaved chat has no project, so the task has none")
        appState.resolveScheduledTaskProposal(id: proposal.id, with: proposal)

        let text = resultText(try await call.value)
        XCTAssertTrue(text.contains("\"project_id\" : null"), text)
        XCTAssertEqual(appState.scheduledTasks.map(\.projectId), [nil])
    }

    func testScheduledTaskToolRejectsUnknownProject() async throws {
        do {
            _ = try await appState.ideHandleToolCall(
                name: "ide__create_scheduled_task",
                arguments: .object([
                    "project_id": .string(UUID().uuidString),
                    "name": .string("Elsewhere"),
                    "prompt": .string("Do it."),
                    "cron_expression": .string("@daily"),
                ]),
                sessionKey: "chat-1"
            )
            XCTFail("An unknown project_id must be rejected")
        } catch {
            XCTAssertTrue(appState.scheduledTaskProposals.isEmpty)
        }
    }

    func testScheduledTaskToolRejectsInvalidCronWithoutPrompting() async throws {
        do {
            _ = try await appState.ideHandleToolCall(
                name: "ide__create_scheduled_task",
                arguments: .object([
                    "project_id": .string(project.id.uuidString),
                    "name": .string("Broken"),
                    "prompt": .string("Do it."),
                    "cron_expression": .string("every day"),
                ]),
                sessionKey: "chat-1"
            )
            XCTFail("An invalid cron expression must be rejected")
        } catch {
            XCTAssertTrue(appState.scheduledTaskProposals.isEmpty)
        }
    }
}
