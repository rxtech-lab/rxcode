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

    override func setUp() async throws {
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
        hook = TaskBoardHook()
        project = Project(name: "P", path: "/tmp/p", gitHubRepo: nil)
        appState.projects = [project]
    }

    override func tearDown() async throws {
        persistence = nil
        appState = nil
        hook = nil
        project = nil
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
}
