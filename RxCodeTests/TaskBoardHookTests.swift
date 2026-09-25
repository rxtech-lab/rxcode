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

    func testHookAdvancesOnCleanCompletion() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(payload(), controller: appState.hookController)

        XCTAssertEqual(outcome.control, .proceed)
        XCTAssertEqual(status(of: task.id), .pendingReview)
    }

    /// In Progress is locked while the agent owns the task, so a stopped turn
    /// must still release it for review rather than strand it.
    func testHookAdvancesCancelledTurn() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(
            payload(reason: .cancelled), controller: appState.hookController
        )

        XCTAssertEqual(outcome.control, .proceed)
        XCTAssertEqual(status(of: task.id), .pendingReview)
    }

    func testHookAdvancesErroredTurn() async {
        let task = makeTask()
        seed([task])

        let outcome = await hook.afterSessionEnd(
            payload(turnDidError: true), controller: appState.hookController
        )

        XCTAssertEqual(outcome.control, .proceed)
        XCTAssertEqual(status(of: task.id), .pendingReview)
    }

    /// A run cut short by quitting the app never reports a session end, so
    /// loading boards releases it.
    func testInterruptedRunsMoveToReviewOnLoad() {
        let running = makeTask()
        let manual = ProjectTask(projectId: running.projectId, title: "No agent", status: .inProgress)
        seed([running, manual])

        appState.releaseInterruptedTasks()

        XCTAssertEqual(status(of: running.id), .pendingReview)
        XCTAssertEqual(status(of: manual.id), .inProgress)
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
