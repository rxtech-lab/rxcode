import Foundation
import Testing
@testable import RxCodeCore

@Suite("Column sorting and device filters")
struct TaskColumnPresentationTests {
    let projectID = UUID()

    @Test("Priority sorts both directions with missing priorities last and stable ties")
    func priority() {
        let urgent = ProjectTask(projectId: projectID, title: "Urgent", priority: .urgent, sortIndex: 2)
        let low = ProjectTask(projectId: projectID, title: "Low", priority: .low, sortIndex: 0)
        let otherUrgent = ProjectTask(projectId: projectID, title: "Other", priority: .urgent, sortIndex: 1)
        let unset = ProjectTask(projectId: projectID, title: "Unset", sortIndex: -1)
        let tasks = [unset, urgent, low, otherUrgent]
        #expect(TaskColumnSort(field: .priority).sorted(tasks).map(\.id) == [otherUrgent.id, urgent.id, low.id, unset.id])
        #expect(TaskColumnSort(field: .priority, descending: true).sorted(tasks).map(\.id) == [low.id, otherUrgent.id, urgent.id, unset.id])
        #expect(TaskColumnSort().sorted(tasks).map(\.id) == [unset.id, low.id, otherUrgent.id, urgent.id])
    }

    @Test("Title, dates and optional release fields sort without changing tasks")
    func properties() {
        let earlier = Date(timeIntervalSince1970: 1)
        let later = Date(timeIntervalSince1970: 2)
        let first = ProjectTask(projectId: projectID, title: "alpha", version: "a", milestone: "a", createdAt: earlier, updatedAt: later)
        let second = ProjectTask(projectId: projectID, title: "Beta", version: "b", milestone: "b", createdAt: later, updatedAt: earlier)
        for field in [TaskColumnSort.Field.title, .createdAt, .version, .milestone] {
            #expect(TaskColumnSort(field: field).sorted([second, first]).map(\.id) == [first.id, second.id])
            #expect(TaskColumnSort(field: field, descending: true).sorted([first, second]).map(\.id) == [second.id, first.id])
        }
        #expect(TaskColumnSort(field: .updatedAt).sorted([first, second]).first?.id == second.id)
        #expect(first.sortIndex == 0)
    }

    @Test("Filters combine properties and persist independently per scope")
    func filters() throws {
        var filter = TaskColumnFilter()
        filter.priorities = [.high, .urgent]
        filter.tags = ["ui", "mobile"]
        filter.versions = ["v2"]
        let task = ProjectTask(projectId: projectID, title: "Match", version: "v2", tags: ["ui", "mobile"], priority: .high)
        #expect(filter.matches(task))
        var missing = task
        missing.tags = ["ui"]
        #expect(!filter.matches(missing))
        missing = task
        missing.priority = nil
        #expect(!filter.matches(missing))
        filter.typeIDs = [UUID()]
        #expect(!filter.matches(task))
        let data = try filter.storing(in: Data(), scope: "phone-project-view-column")
        #expect(TaskColumnFilter.load(from: data, scope: "phone-project-view-column") == filter)
        #expect(TaskColumnFilter.load(from: data, scope: "other-view-column").isEmpty)
        let cleared = try TaskColumnFilter().storing(in: data, scope: "phone-project-view-column")
        #expect(TaskColumnFilter.load(from: cleared, scope: "phone-project-view-column").isEmpty)
    }

    @Test("Saved views and cloud mapping preserve sorting, never device filters; old views use manual order")
    func serialization() throws {
        var view = TaskSavedView.defaultView
        view.columnSorts[TaskStatus.pending.rawValue] = TaskColumnSort(field: .priority)
        let board = TaskBoard(savedViews: [view])
        let encoded = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: encoded)
        #expect(decoded.defaultView.sort(for: .pending).field == .priority)
        #expect(decoded.defaultView.sort(for: .done).field == .manual)
        let legacy = try JSONDecoder().decode(TaskSavedView.self, from: Data(#"{"name":"Legacy"}"#.utf8))
        #expect(legacy.sort(for: .pending).field == .manual)
        let sync = CloudBoardSyncState()
        let cloud = CloudSavedViews(views: [CloudSavedView(view: view, sync: sync)])
        let restored = try JSONDecoder().decode(CloudSavedViews.self, from: JSONEncoder().encode(cloud))
        #expect(restored.views[0].localView(sync: sync).columnSorts == view.columnSorts)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("deviceColumnFilters"))
    }
}
