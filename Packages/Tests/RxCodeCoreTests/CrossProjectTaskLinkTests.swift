import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cross-project task links")
struct CrossProjectTaskLinkTests {
    private func lookup(_ boards: TaskBoard...) -> [UUID: ProjectTask] {
        Dictionary(boards.flatMap(\.tasks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("A parent on another board links, and cycles across boards are rejected")
    func linkValidationAcrossBoards() {
        let first = ProjectTask(projectId: UUID(), title: "API")
        let second = ProjectTask(projectId: UUID(), parentTaskId: first.id, title: "Client")
        let all = lookup(TaskBoard(tasks: [first]), TaskBoard(tasks: [second]))

        #expect(TaskBoard.canLinkTask(second.id, to: first.id, in: all))
        #expect(!TaskBoard.canLinkTask(first.id, to: second.id, in: all))
        #expect(!TaskBoard(tasks: [second]).canLinkTask(second.id, to: first.id))
    }

    @Test("Cycle detection follows every parent branch")
    func cycleThroughSecondParent() {
        let root = ProjectTask(projectId: UUID(), title: "Root")
        let other = ProjectTask(projectId: UUID(), title: "Other")
        let child = ProjectTask(projectId: UUID(), parentTaskIds: [other.id, root.id], title: "Child")
        let all = lookup(TaskBoard(tasks: [root, other, child]))
        #expect(!TaskBoard.canLinkTask(root.id, to: child.id, in: all))
        #expect(TaskBoard.canLinkTask(other.id, to: root.id, in: all))
    }

    @Test("Parent choices exclude tasks that would close a cycle through another board")
    func parentGroupsAcrossBoards() {
        let root = ProjectTask(projectId: UUID(), title: "Root")
        let child = ProjectTask(projectId: UUID(), parentTaskId: root.id, title: "Child")
        let rootBoard = TaskBoard(tasks: [root])
        let childBoard = TaskBoard(tasks: [child])
        let all = lookup(rootBoard, childBoard)

        #expect(rootBoard.parentTaskGroups(for: child.id, linkingAcross: all).flatMap(\.tasks).map(\.id) == [root.id])
        #expect(childBoard.parentTaskGroups(for: root.id, linkingAcross: all).isEmpty)
    }

    @Test("A child advances when its parent on another board is ready")
    func advanceWithExternalParent() {
        let parent = ProjectTask(projectId: UUID(), title: "Parent", status: .pendingReview)
        let child = ProjectTask(projectId: UUID(), parentTaskId: parent.id, title: "Child", status: .pending)
        let parentBoard = TaskBoard(tasks: [parent])
        var childBoard = TaskBoard(tasks: [child])

        #expect(childBoard.advanceChildren(of: childBoard.readyParentIDs()).isEmpty)
        #expect(childBoard.tasks[0].status == .pending)
        _ = childBoard.advanceChildren(of: parentBoard.readyParentIDs())
        #expect(childBoard.tasks[0].status == .inProgress)
    }

    @Test("A child with parents on two boards waits for both")
    func advanceWithTwoExternalParents() {
        let first = ProjectTask(projectId: UUID(), title: "First", status: .pendingReview)
        let second = ProjectTask(projectId: UUID(), title: "Second", status: .pending)
        let child = ProjectTask(projectId: UUID(), parentTaskIds: [first.id, second.id], title: "Child")
        var childBoard = TaskBoard(tasks: [child])
        #expect(childBoard.advanceChildren(of: [first.id]).isEmpty)
        #expect(childBoard.tasks[0].status == .pending)
        #expect(childBoard.advanceChildren(of: [first.id, second.id]).map(\.id) == [child.id])
    }

    @Test("A cloud pull keeps a parent from another board and still applies same-board links")
    func cloudPullKeepsCrossBoardParent() {
        let externalParent = UUID()
        let task = ProjectTask(projectId: UUID(), parentTaskId: externalParent, title: "Task")
        let board = TaskBoard(tasks: [task])
        let pulled = board.applying(CloudTaskFields(title: "Renamed"), to: task, sync: CloudBoardSyncState(), updatedAt: nil)
        #expect(pulled.parentTaskId == externalParent)
        #expect(pulled.title == "Renamed")

        let sibling = ProjectTask(projectId: task.projectId, title: "Sibling")
        var sync = CloudBoardSyncState()
        sync.tasks[sibling.id] = CloudItemLink(remoteId: "remote-sibling", base: CloudTaskFields(title: "Sibling"))
        let linked = TaskBoard(tasks: [task, sibling])
            .applying(CloudTaskFields(title: "Task", parentTaskId: "remote-sibling"), to: task, sync: sync, updatedAt: nil)
        #expect(linked.parentTaskId == sibling.id)

        var local = task
        local.parentTaskId = sibling.id
        let unlinked = TaskBoard(tasks: [local, sibling])
            .applying(CloudTaskFields(title: "Task"), to: local, sync: sync, updatedAt: nil)
        #expect(unlinked.parentTaskId == nil)

        let multi = ProjectTask(projectId: task.projectId, parentTaskIds: [externalParent, sibling.id], title: "Multi")
        let multiBoard = TaskBoard(tasks: [multi, sibling])
        #expect(multiBoard.cloudFields(for: multi, sync: sync).parentTaskId == "remote-sibling")
        let roundTripped = multiBoard.applying(
            CloudTaskFields(title: "Multi", parentTaskId: "remote-sibling"),
            to: multi, sync: sync, updatedAt: nil
        )
        #expect(Set(roundTripped.parentTaskIds) == [externalParent, sibling.id])
    }
}
