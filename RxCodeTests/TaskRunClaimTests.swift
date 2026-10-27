import XCTest
import RxCodeCore
@testable import RxCode

/// Covers which device runs a cloud task: a move on this Mac locks the run
/// here, a card claimed by another device is left alone and shows where it
/// runs, and only cards entering a chat column from elsewhere start runs.
@MainActor
final class TaskRunClaimTests: XCTestCase {

    private var appState: AppState!
    private var project: Project!

    override func setUp() async throws {
        appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        project = Project(name: "P", path: "/tmp/p", gitHubRepo: nil, cloudId: "cloud-project")
        appState.projects = [project]
    }

    override func tearDown() async throws {
        appState = nil
        project = nil
    }

    private func makeTask(_ title: String, status: TaskStatus, sortIndex: Double = 1) -> ProjectTask {
        ProjectTask(
            projectId: project.id,
            title: title,
            status: status,
            agent: TaskAgentConfig(provider: .claudeCode, model: "opus"),
            sortIndex: sortIndex
        )
    }

    private func seed(_ tasks: [ProjectTask]) {
        let columns = TaskColumn.defaults.map { column -> TaskColumn in
            var column = column
            if column.id == .inProgress { column.concurrencyLimit = 1 }
            return column
        }
        appState.taskBoards[project.id] = TaskBoard(tasks: tasks, columns: columns)
    }

    func testMovingIntoChatColumnLocksRunToThisDevice() async {
        // A busy slot queues the moved task, so no agent is launched.
        let running = makeTask("Running", status: .inProgress)
        let moved = makeTask("Moved", status: .pending)
        seed([running, moved])
        appState.dispatchingTaskIds.insert(running.id)

        appState.moveTask(moved, to: .inProgress)

        XCTAssertEqual(appState.task(id: moved.id)?.assignedDeviceId, appState.cloudDeviceID)
        XCTAssertFalse(appState.isRunningOnOtherDevice(appState.task(id: moved.id)!))
    }

    func testLocalProjectRunsAreNotClaimed() {
        var local = project!
        local.cloudId = nil
        appState.projects = [local]
        let task = makeTask("Local", status: .pending)
        seed([task])

        XCTAssertNil(appState.claimedForThisDevice(task).assignedDeviceId)
    }

    func testCardClaimedByAnotherDeviceShowsWhereItRuns() {
        var task = makeTask("Elsewhere", status: .inProgress)
        task.assignedDeviceId = "other-mac"
        seed([task])
        appState.cloudDevices = [CloudDevice(id: "other-mac", name: "Studio Mac")]

        XCTAssertTrue(appState.isRunningOnOtherDevice(task))
        XCTAssertEqual(appState.otherRunDeviceName(for: task), "Studio Mac")

        appState.cloudDevices = []
        XCTAssertEqual(appState.otherRunDeviceName(for: task), "another device", "a teammate's Mac has no name here")

        var parked = task
        parked.status = .pendingReview
        XCTAssertFalse(appState.isRunningOnOtherDevice(parked), "outside a chat column nothing is running")
    }

    func testCardRunningOnAnotherDeviceCannotBeMovedOut() {
        var task = makeTask("Elsewhere", status: .inProgress)
        task.assignedDeviceId = "other-mac"
        seed([task])

        appState.moveTask(task, to: .done)

        XCTAssertEqual(appState.task(id: task.id)?.status, .inProgress)
    }

    func testRunClaimedElsewhereIsLeftAloneWithoutAttention() async {
        var task = makeTask("Elsewhere", status: .inProgress)
        task.assignedDeviceId = "other-mac"
        seed([task])

        await appState.startTask(task)

        let stored = appState.task(id: task.id)
        XCTAssertNil(stored?.sessionKey, "another device owns the run")
        XCTAssertNil(stored?.attentionReason, "losing the claim is not an error")
    }

    func testOnlyCardsEnteringAChatColumnStartRemoteRuns() {
        let pending = makeTask("Pending", status: .pending)
        seed([pending])
        let board = appState.taskBoard(for: project.id)
        var entered = pending
        entered.status = .inProgress

        XCTAssertTrue(appState.remoteMoveStartsRun(from: pending, to: entered, board: board))
        XCTAssertTrue(appState.remoteMoveStartsRun(from: nil, to: entered, board: board), "a new card created in a chat column")
        XCTAssertFalse(appState.remoteMoveStartsRun(from: entered, to: entered, board: board), "already in a chat column")

        var claimedElsewhere = entered
        claimedElsewhere.assignedDeviceId = "other-mac"
        XCTAssertFalse(appState.remoteMoveStartsRun(from: pending, to: claimedElsewhere, board: board))

        var claimedHere = entered
        claimedHere.assignedDeviceId = appState.cloudDeviceID
        XCTAssertTrue(appState.remoteMoveStartsRun(from: pending, to: claimedHere, board: board))
    }
}
