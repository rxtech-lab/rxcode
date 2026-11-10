import Foundation
import Testing
@testable import RxCodeCore

@Suite("MCP task views")
struct TaskViewsToolTests {
    @Test("The tool is available to every backend")
    func registration() throws {
        let tool = try #require(IDEToolRegistry.allTools.first { $0.name == TaskViewsTool.name })
        if case .alwaysIDEOnly = tool.visibility {} else { Issue.record("Task views must be available to all backends") }
        #expect(tool.inputSchema["required"] == .array([.string("operation")]))
    }

    @Test("Listing includes the implicit board and never persists it")
    func list() throws {
        var board = TaskBoard()
        let result = try TaskViewsTool.apply(.object(["operation": .string("list")]), to: &board)
        #expect(result.arrayValue?.first?["id"]?.stringValue == TaskSavedView.defaultViewId.uuidString)
        #expect(board.savedViews.isEmpty)
    }

    @Test("Create and partial update preserve settings and the default invariant")
    func createUpdate() throws {
        var board = TaskBoard()
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("create"), "name": .string(" Release "), "layout": .string("table"),
            "tags": .array([.string("mcp")]), "versions": .array([.string("v2.0.0")]),
            "is_default": .bool(true), "is_hidden": .bool(true),
            "statuses": .array([.string("backlog")]),
            "filter_script": .string("return true"),
            "column_sorts": .object(["backlog": .object(["field": .string("priority"), "descending": .bool(true)])]),
        ]), to: &board)
        let view = try #require(board.savedViews.last)
        #expect(board.savedViews.count == 2)
        #expect(view.name == "Release")
        #expect(view.layout == .table)
        #expect(view.isHidden)
        #expect(view.columnSorts["backlog"]?.field == .priority)
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("update"), "view_id": .string(view.id.uuidString),
            "name": .string("Renamed"), "tags": .array([]), "filter_script": .null,
        ]), to: &board)
        let changed = try #require(board.savedViews.last)
        #expect(changed.tags.isEmpty)
        #expect(changed.filterScript == nil)
        #expect(changed.versions == ["v2.0.0"])
        #expect(changed.layout == .table)
        #expect(changed.isHidden)
        #expect(changed.columnSorts == view.columnSorts)
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("update"), "view_id": .string(TaskSavedView.defaultViewId.uuidString),
            "is_default": .bool(true),
        ]), to: &board)
        #expect(board.savedViews.filter(\.isDefault).count == 1)
        #expect(board.defaultView.id == TaskSavedView.defaultViewId)
    }

    @Test("Story and column filters survive persistence and can be cleared")
    func filters() throws {
        let story = ProjectStory(projectId: UUID(), title: "v2")
        var board = TaskBoard(stories: [story])
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("update"), "view_id": .string(TaskSavedView.defaultViewId.uuidString),
            "story_ids": .array([.string(story.id.uuidString)]),
            "statuses": .array([.string("backlog")]),
            "story_panel_statuses": .array([.string("done")]),
            "milestones": .array([.string("v2")]),
        ]), to: &board)
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        #expect(decoded.defaultView.storyIds == [story.id])
        #expect(decoded.defaultView.statuses == [.backlog])
        #expect(decoded.defaultView.storyPanelStatuses == [.done])
        #expect(decoded.defaultView.milestones == ["v2"])
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("update"), "view_id": .string(TaskSavedView.defaultViewId.uuidString),
            "story_ids": .array([]), "statuses": .array([]),
        ]), to: &board)
        #expect(board.defaultView.storyIds.isEmpty)
        #expect(board.defaultView.statuses.isEmpty)
        #expect(board.defaultView.milestones == ["v2"])
    }

    @Test("Reorder includes hidden views; deleting a view keeps tasks")
    func reorderDelete() throws {
        let project = UUID()
        let task = ProjectTask(projectId: project, title: "Keep me")
        var board = TaskBoard(tasks: [task])
        var view = TaskSavedView(name: "Hidden")
        view.isHidden = true
        board.upsertSavedView(view)
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("reorder"),
            "view_ids": .array([.string(view.id.uuidString), .string(TaskSavedView.defaultViewId.uuidString)]),
        ]), to: &board)
        #expect(board.effectiveViews.map(\.id) == [view.id, TaskSavedView.defaultViewId])
        _ = try TaskViewsTool.apply(.object([
            "operation": .string("delete"), "view_id": .string(view.id.uuidString),
        ]), to: &board)
        #expect(board.tasks.map(\.id) == [task.id])
        #expect(board.defaultView.id == TaskSavedView.defaultViewId)
        #expect(throws: IDEToolError.self) {
            _ = try TaskViewsTool.apply(.object([
                "operation": .string("delete"), "view_id": .string(TaskSavedView.defaultViewId.uuidString),
            ]), to: &board)
        }
    }

    @Test("Invalid requests fail without partial mutations")
    func invalidRequests() throws {
        let original = TaskBoard()
        let requests: [JSONValue] = [
            .object(["operation": .string("create"), "name": .string(" ")]),
            .object(["operation": .string("create"), "name": .string("Bad"), "layout": .string("grid")]),
            .object(["operation": .string("create"), "name": .string("Bad"), "is_hidden": .string("true")]),
            .object(["operation": .string("create"), "name": .string("Bad"), "tags": .null]),
            .object(["operation": .string("create"), "name": .string("Bad"), "statuses": .array([.string("unknown")])]),
            .object(["operation": .string("create"), "name": .string("Bad"), "story_ids": .array([.string(UUID().uuidString)])]),
            .object(["operation": .string("create"), "name": .string("Bad"), "column_sorts": .object(["backlog": .object(["field": .string("unknown"), "descending": .bool(false)])])]),
            .object(["operation": .string("update"), "view_id": .string(UUID().uuidString), "name": .string("Bad")]),
            .object(["operation": .string("delete"), "view_id": .string("invalid")]),
            .object(["operation": .string("reorder"), "view_ids": .array([])]),
            .object(["operation": .string("reorder"), "view_ids": .array([
                .string(TaskSavedView.defaultViewId.uuidString), .string(TaskSavedView.defaultViewId.uuidString),
            ])]),
            .object(["operation": .string("list"), "name": .string("Unused")]),
            .object(["operation": .string("unknown")]),
        ]
        for request in requests {
            var board = original
            #expect(throws: IDEToolError.self) { _ = try TaskViewsTool.apply(request, to: &board) }
            #expect(board.savedViews == original.savedViews)
        }
    }
}
