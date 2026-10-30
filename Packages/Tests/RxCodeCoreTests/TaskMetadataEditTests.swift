import XCTest
@testable import RxCodeCore

final class TaskMetadataEditTests: XCTestCase {
    func testUnusedValuesSurvivePersistence() throws {
        var board = TaskBoard()
        TaskMetadataEdit(field: .versions, name: " v2.0.0 ").apply(to: &board)
        TaskMetadataEdit(field: .milestones, name: "v2").apply(to: &board)
        TaskMetadataEdit(field: .tags, name: "ui").apply(to: &board)
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(decoded.allVersions, ["v2.0.0"])
        XCTAssertEqual(decoded.allMilestones, ["v2"])
        XCTAssertEqual(decoded.allTags, ["ui"])
    }

    func testLegacyBoardDefaultsToEmptyCatalogs() throws {
        let board = try JSONDecoder().decode(TaskBoard.self, from: Data("{}".utf8))
        XCTAssertTrue(board.versions.isEmpty)
        XCTAssertTrue(board.milestones.isEmpty)
    }

    func testRenamesReachTasksAndStories() {
        let projectID = UUID()
        let task = ProjectTask(projectId: projectID, title: "Task", version: "old", tags: ["old"], milestone: "old")
        let story = ProjectStory(projectId: projectID, title: "Story", tags: ["old"], version: "old", milestone: "old")
        var board = TaskBoard(stories: [story], tasks: [task])
        for field in TaskMetadataEdit.Field.allCases {
            TaskMetadataEdit(field: field, original: "old", name: "new").apply(to: &board)
        }
        XCTAssertEqual(board.tasks[0].tags, ["new"])
        XCTAssertEqual(board.tasks[0].version, "new")
        XCTAssertEqual(board.tasks[0].milestone, "new")
        XCTAssertEqual(board.stories[0].tags, ["new"])
        XCTAssertEqual(board.stories[0].version, "new")
        XCTAssertEqual(board.stories[0].milestone, "new")
    }

    func testRenameMergesFiltersAndUpdatesOpenDraft() {
        var view = TaskSavedView(name: "Release")
        view.tags = ["old", "new"]
        view.versions = ["old", "new"]
        view.milestones = ["old", "new"]
        var board = TaskBoard(savedViews: [view], labels: [TaskLabel(name: "old"), TaskLabel(name: "new")], versions: ["old", "new"], milestones: ["old", "new"])
        for field in TaskMetadataEdit.Field.allCases {
            let edit = TaskMetadataEdit(field: field, original: "old", name: "new")
            edit.apply(to: &board)
            edit.apply(to: &view)
            XCTAssertEqual(field.values(in: board), ["new"])
        }
        XCTAssertEqual(board.savedViews[0].tags, ["new"])
        XCTAssertEqual(board.savedViews[0].versions, ["new"])
        XCTAssertEqual(board.savedViews[0].milestones, ["new"])
        XCTAssertEqual(view.tags, ["new"])
        XCTAssertEqual(view.versions, ["new"])
        XCTAssertEqual(view.milestones, ["new"])
    }
}
