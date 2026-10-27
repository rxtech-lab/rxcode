import XCTest
import RxCodeCore
@testable import RxCode

/// Which tab `TaskFormSheet` opens on when a story or task is created from a
/// board menu, a "+" button, or an edit.
final class TaskCreationModeTests: XCTestCase {

    // MARK: - Editing

    func testExistingRecord_alwaysOpensOnTheForm() {
        for isStory in [true, false] {
            for requested in [TaskCreationMode.ai, .form, nil] {
                XCTAssertEqual(
                    TaskCreationMode.resolved(isExistingRecord: true, isStory: isStory, requested: requested),
                    .form,
                    "A saved record has nothing left to draft, so \(requested as Any) must not open the AI tab"
                )
            }
        }
    }

    // MARK: - Creating without a requested tab

    func testNewStory_defaultsToAI() {
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: true, requested: nil),
            .ai,
            "A story is outlined from a description by default"
        )
    }

    func testNewTask_defaultsToForm() {
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: false, requested: nil),
            .form,
            "A task is written straight into the fields by default"
        )
    }

    // MARK: - Creating with a requested tab

    func testRequestedTabWinsOverTheKindDefault() {
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: false, requested: .ai),
            .ai,
            "\"New Task → With AI\" must open the AI tab"
        )
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: true, requested: .form),
            .form,
            "\"New Story → With Form\" must open the form"
        )
    }
}

@MainActor
final class TaskContextMenuStateTests: XCTestCase {
    func testCardAndBackgroundBoardUpdatesKeepMenuStable() {
        var task = ProjectTask(projectId: UUID(), title: "Move this task")
        var board = TaskBoard(tasks: [task])
        let original = TaskContextMenuState(task: task, board: board, canOpenChat: true)

        task.title = "Updated while the menu is open"
        task.details = "New background content"
        task.updatedAt = Date().addingTimeInterval(10)
        board.tasks = [task, ProjectTask(projectId: task.projectId, title: "Another task")]

        XCTAssertEqual(original, TaskContextMenuState(task: task, board: board, canOpenChat: true))
    }

    func testDestinationChangesAndChatAvailabilityRefreshMenu() {
        let task = ProjectTask(projectId: UUID(), title: "Move this task")
        var board = TaskBoard(tasks: [task], columns: TaskColumn.defaults)
        let original = TaskContextMenuState(task: task, board: board, canOpenChat: false)
        XCTAssertNotEqual(original, TaskContextMenuState(task: task, board: board, canOpenChat: true))

        board.columns[0].name = "Renamed destination"
        XCTAssertNotEqual(original, TaskContextMenuState(task: task, board: board, canOpenChat: false))
    }

    func testCurrentDestinationAndAgentLockRemainAccurate() {
        var task = ProjectTask(
            projectId: UUID(), title: "Move this task", status: .pending,
            agent: TaskAgentConfig(provider: .claudeCode, model: "opus"), sessionKey: "session"
        )
        let board = TaskBoard(tasks: [task])
        let pending = TaskContextMenuState(task: task, board: board, canOpenChat: true)
        XCTAssertEqual(pending.currentStatus, .pending)
        XCTAssertFalse(pending.isStatusLocked)
        XCTAssertTrue(pending.canRunWithAgent)

        task.status = .inProgress
        let running = TaskContextMenuState(task: task, board: board, canOpenChat: true)
        XCTAssertNotEqual(pending, running)
        XCTAssertEqual(running.currentStatus, .inProgress)
        XCTAssertTrue(running.isStatusLocked)
        XCTAssertFalse(running.canRunWithAgent)
    }
}
