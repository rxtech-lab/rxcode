import XCTest
import RxCodeCore
@testable import RxCode

/// Covers a chat column's concurrency limit: tasks beyond it wait as queued,
/// the queue can be reordered, and a freed slot starts the next queued task.
@MainActor
final class TaskRunQueueTests: XCTestCase {

    private var appState: AppState!
    private var project: Project!

    override func setUp() async throws {
        appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        project = Project(name: "P", path: "/tmp/p", gitHubRepo: nil)
        appState.projects = [project]
    }

    override func tearDown() async throws {
        appState = nil
        project = nil
    }

    private func makeTask(_ title: String, status: TaskStatus = .inProgress, queued: Bool = false, sortIndex: Double) -> ProjectTask {
        ProjectTask(
            projectId: project.id,
            title: title,
            status: status,
            agent: TaskAgentConfig(provider: .claudeCode, model: "opus"),
            isQueued: queued,
            sortIndex: sortIndex
        )
    }

    /// The default board with In Progress limited to `limit` runs.
    private func seed(_ tasks: [ProjectTask], limit: Int) {
        let columns = TaskColumn.defaults.map { column -> TaskColumn in
            var column = column
            if column.id == .inProgress { column.concurrencyLimit = limit }
            return column
        }
        appState.taskBoards[project.id] = TaskBoard(tasks: tasks, columns: columns)
    }

    func testTaskBeyondLimitIsQueuedInsteadOfStarted() async {
        let running = makeTask("Running", sortIndex: 1)
        let next = makeTask("Next", status: .pending, sortIndex: 1)
        seed([running, next], limit: 1)
        appState.dispatchingTaskIds.insert(running.id)

        await appState.startTask(next)

        let stored = appState.task(id: next.id)
        XCTAssertEqual(stored?.status, .inProgress)
        XCTAssertEqual(stored?.isQueued, true)
        XCTAssertNil(stored?.sessionKey, "a queued task must not open a thread")
        XCTAssertFalse(appState.isStatusLocked(stored!), "queued cards stay draggable")
        XCTAssertEqual(appState.runningTaskCount(in: .inProgress, projectId: project.id), 1)
    }

    func testQueuedTasksCanBeReordered() {
        let first = makeTask("First", queued: true, sortIndex: 1)
        let second = makeTask("Second", queued: true, sortIndex: 2)
        let third = makeTask("Third", queued: true, sortIndex: 3)
        seed([first, second, third], limit: 1)

        appState.reorderQueuedTask(third.id, before: first.id)
        XCTAssertEqual(appState.taskBoard(for: project.id).queuedTasks(in: .inProgress).map(\.id), [third.id, first.id, second.id])

        appState.reorderQueuedTask(third.id, before: nil)
        XCTAssertEqual(appState.taskBoard(for: project.id).queuedTasks(in: .inProgress).map(\.id), [first.id, second.id, third.id])
    }

    func testMovingQueuedTaskOutOfChatColumnLeavesQueue() {
        let queued = makeTask("Queued", queued: true, sortIndex: 1)
        seed([queued], limit: 1)

        appState.moveTask(queued, to: .backlog)

        XCTAssertEqual(appState.task(id: queued.id)?.status, .backlog)
        XCTAssertEqual(appState.task(id: queued.id)?.isQueued, false)
    }

    func testFreedSlotStartsFirstQueuedTaskInOrder() async {
        // Assigned to another Mac, so a dispatched run stops before sending.
        var first = makeTask("First", queued: true, sortIndex: 2)
        first.assignedDeviceId = "another-mac"
        var second = makeTask("Second", queued: true, sortIndex: 3)
        second.assignedDeviceId = "another-mac"
        seed([first, second], limit: 1)

        appState.dispatchQueuedTasks(in: project.id)
        XCTAssertTrue(appState.dispatchingTaskIds.isEmpty, "nothing starts before launch finishes")

        appState.isTaskQueueDispatchEnabled = true
        appState.dispatchQueuedTasks(in: project.id)
        XCTAssertEqual(appState.dispatchingTaskIds, [first.id], "only one slot is free, taken by the queue head")

        // The bailed-out run frees its slot, which starts the next task.
        for _ in 0..<100 where !appState.dispatchingTaskIds.isEmpty || appState.task(id: second.id)?.isQueued == true {
            await Task.yield()
        }
        XCTAssertTrue(appState.dispatchingTaskIds.isEmpty, "reservations are released when a run bails out")
        XCTAssertEqual(appState.task(id: first.id)?.isQueued, false)
        XCTAssertEqual(appState.task(id: second.id)?.isQueued, false)
    }

    func testConcurrencyLimitIsClampedAndDecodesWithDefault() throws {
        seed([], limit: 4)
        appState.setConcurrencyLimit(0, for: .inProgress, projectId: project.id)
        XCTAssertEqual(appState.taskBoard(for: project.id).column(for: .inProgress).concurrencyLimit, 1)

        let legacy = Data(#"{"id":"in_progress","name":"In Progress","triggersChat":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TaskColumn.self, from: legacy).concurrencyLimit, TaskColumn.defaultConcurrencyLimit)
    }
}
