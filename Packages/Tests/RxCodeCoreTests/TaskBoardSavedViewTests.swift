import Foundation
import Testing
@testable import RxCodeCore

@Suite("Task board saved views")
struct TaskBoardSavedViewTests {
    @Test("Visibility survives persistence without removing saved settings or order")
    func visibilityPersistence() throws {
        let legacy = try JSONDecoder().decode(TaskSavedView.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(!legacy.isHidden)
        var board = TaskBoard()
        var hidden = TaskSavedView(name: "Release", versions: ["2.0"], isDefault: true)
        board.upsertSavedView(hidden)
        let order = board.effectiveViews.map(\.id)
        hidden.isHidden = true
        board.upsertSavedView(hidden)
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        #expect(decoded.effectiveViews.map(\.id) == order)
        #expect(!decoded.visibleViews.contains { $0.id == hidden.id })
        #expect(decoded.defaultView.isHidden)
        hidden.isHidden = false
        board.upsertSavedView(hidden)
        #expect(board.visibleViews.map(\.id) == order)
        #expect(board.defaultView.versions == ["2.0"])
        for var view in board.effectiveViews {
            view.isHidden = true
            board.upsertSavedView(view)
        }
        #expect(board.visibleViews.isEmpty)
        #expect(board.effectiveViews.count == order.count)
    }

    @Test("The default view falls back to the first tab and stays unique")
    func defaultView() throws {
        var board = TaskBoard()
        #expect(board.defaultView.id == TaskSavedView.defaultViewId)

        let table = TaskSavedView(name: "Table", layout: .table)
        board.upsertSavedView(table)
        #expect(board.savedViews.map(\.id) == [TaskSavedView.defaultViewId, table.id])
        #expect(board.defaultView.id == TaskSavedView.defaultViewId)

        board.setDefaultView(table.id)
        #expect(board.defaultView.id == table.id)

        board.setDefaultView(TaskSavedView.defaultViewId)
        #expect(board.defaultView.id == TaskSavedView.defaultViewId)
        #expect(board.savedViews.filter(\.isDefault).count == 1)

        board.savedViews.removeAll { $0.id == TaskSavedView.defaultViewId }
        #expect(board.defaultView.id == table.id)

        var marked = table
        marked.isDefault = true
        let decoded = try JSONDecoder().decode(TaskSavedView.self, from: JSONEncoder().encode(marked))
        #expect(decoded.isDefault)
        let legacy = try JSONDecoder().decode(TaskSavedView.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(!legacy.isDefault)
    }

    @Test("A view narrows the tasks and stories a dashboard shows")
    func viewMatching() {
        let projectId = UUID()
        let ui = ProjectStory(projectId: projectId, title: "UI", tags: ["ui"])
        let api = ProjectStory(projectId: projectId, title: "API")
        let tagged = ProjectTask(projectId: projectId, title: "Tagged", tags: ["ui"])
        let plain = ProjectTask(projectId: projectId, title: "Plain")
        let board = TaskBoard(stories: [ui, api], tasks: [tagged, plain])
        let view = TaskSavedView(name: "UI", tags: ["ui"])
        #expect(board.tasks(matching: view).map(\.id) == [tagged.id])
        #expect(board.stories(matching: view).map(\.id) == [ui.id])
        #expect(board.stories(matching: .defaultView).count == 2)
    }
}
