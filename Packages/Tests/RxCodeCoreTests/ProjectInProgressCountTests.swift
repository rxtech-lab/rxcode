import Foundation
import Testing
@testable import RxCodeCore

@Suite("Project in-progress count")
struct ProjectInProgressCountTests {
    @Test("Default columns count only In Progress, including queued tasks")
    func defaultColumns() {
        let projectID = UUID()
        var queued = ProjectTask(projectId: projectID, title: "Queued", status: .inProgress)
        queued.isQueued = true
        var board = TaskBoard(tasks: [.backlog, .pending, .inProgress, .pendingReview, .done].map {
            ProjectTask(projectId: projectID, title: $0.rawValue, status: $0)
        } + [queued])
        #expect(board.inProgressTaskCount == 2)
        board.tasks.removeAll()
        #expect(board.inProgressTaskCount == 0)
    }

    @Test("Custom agent columns count; completed and deleted columns resolve correctly")
    func customColumns() {
        let working = TaskColumn(name: "Working", triggersChat: true)
        let completed = TaskColumn(name: "Completed", triggersChat: true, countsAsDone: true)
        let projectID = UUID()
        var board = TaskBoard(tasks: [working.id, completed.id, .inProgress].map {
            ProjectTask(projectId: projectID, title: $0.rawValue, status: $0)
        }, columns: [TaskColumn(id: .pending, name: "Pending"), working, completed])
        #expect(board.inProgressTaskCount == 1)
        board.tasks[0].status = completed.id
        #expect(board.inProgressTaskCount == 0)
    }
}
