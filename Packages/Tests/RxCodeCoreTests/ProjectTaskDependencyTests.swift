import Foundation
import Testing
@testable import RxCodeCore

@Suite("Task dependencies")
struct ProjectTaskDependencyTests {
    @Test("Multiple parents round trip and legacy parent links migrate")
    func multipleParentCoding() throws {
        let first = UUID()
        let second = UUID()
        let task = ProjectTask(projectId: UUID(), parentTaskIds: [first, second, first], title: "Child")
        let encoded = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ProjectTask.self, from: encoded)
        #expect(decoded.parentTaskIds == [first, second])

        let legacy = #"{"title":"Child","parentTaskId":"\#(first.uuidString)"}"#
        let migrated = try JSONDecoder().decode(ProjectTask.self, from: Data(legacy.utf8))
        #expect(migrated.parentTaskIds == [first])
    }

    @Test("A parent reaching Pending Review starts queued children once")
    func linkedTaskCompletion() {
        let projectID = UUID()
        let parent = ProjectTask(projectId: projectID, title: "Parent", status: .inProgress)
        let child = ProjectTask(projectId: projectID, parentTaskId: parent.id, title: "Child", status: .pending)
        let finishedChild = ProjectTask(projectId: projectID, parentTaskId: parent.id, title: "Already done", status: .done)
        let reviewingChild = ProjectTask(projectId: projectID, parentTaskId: parent.id, title: "In review", status: .pendingReview)
        let needsAttention = ProjectTask(projectId: projectID, parentTaskId: parent.id, title: "Needs attention", status: .pending, attentionReason: "Check failed")
        let unrelated = ProjectTask(projectId: projectID, title: "Unrelated", status: .pending)
        var board = TaskBoard(tasks: [parent, child, finishedChild, reviewingChild, needsAttention, unrelated])
        #expect(!board.readyParentIDs().contains(parent.id))
        board.tasks[0].status = .pendingReview

        let ready = board.readyParentIDs()
        #expect(ready.contains(parent.id))
        let dispatched = board.advanceChildren(of: ready)
        #expect(dispatched.map(\.id) == [child.id])
        #expect(board.tasks.first { $0.id == child.id }?.status == .inProgress)
        #expect(board.tasks.first { $0.id == finishedChild.id }?.status == .done)
        #expect(board.tasks.first { $0.id == reviewingChild.id }?.status == .pendingReview)
        #expect(board.tasks.first { $0.id == needsAttention.id }?.status == .pending)
        #expect(board.tasks.first { $0.id == unrelated.id }?.status == .pending)
        #expect(board.advanceChildren(of: ready).isEmpty)
    }

    @Test("A child waits for every parent")
    func multipleParentsMustBeReady() {
        let projectID = UUID()
        let first = ProjectTask(projectId: projectID, title: "First", status: .pendingReview)
        let second = ProjectTask(projectId: projectID, title: "Second", status: .pending)
        let child = ProjectTask(projectId: projectID, parentTaskIds: [first.id, second.id], title: "Child")
        var board = TaskBoard(tasks: [first, second, child])

        #expect(board.advanceChildren(of: board.readyParentIDs()).isEmpty)
        #expect(board.tasks[2].status == .pending)
        board.tasks[1].status = .done
        #expect(board.advanceChildren(of: board.readyParentIDs()).map(\.id) == [child.id])
        #expect(board.tasks[2].status == .inProgress)
    }

    @Test("An already reviewing parent releases a pending child with an earlier session")
    func linkedTaskCompletionAfterEarlierRun() {
        let projectID = UUID()
        let parent = ProjectTask(projectId: projectID, title: "Parent", status: .pendingReview)
        let child = ProjectTask(
            projectId: projectID, parentTaskId: parent.id, title: "Child", status: .pending,
            agent: TaskAgentConfig(provider: .codex), sessionKey: "earlier-session"
        )
        var board = TaskBoard(tasks: [parent, child])

        let ready = board.readyParentIDs()
        let dispatched = board.advanceChildren(of: ready)

        #expect(dispatched.map(\.id) == [child.id])
        #expect(board.tasks[1].status == .inProgress)
        #expect(board.tasks[1].sessionKey == "earlier-session")
        #expect(board.advanceChildren(of: [parent.id]).isEmpty)
    }

    @Test("A parent in Done also releases a queued child")
    func linkedTaskDoneFallback() {
        let projectID = UUID()
        let parent = ProjectTask(projectId: projectID, title: "Parent", status: .done)
        let child = ProjectTask(projectId: projectID, parentTaskId: parent.id, title: "Child", status: .pending)
        var board = TaskBoard(tasks: [parent, child])

        let ready = board.readyParentIDs()
        #expect(ready == [parent.id])
        #expect(board.advanceChildren(of: ready).map(\.id) == [child.id])
    }

    @Test("Links reject self, missing parents, and cycles")
    func linkedTaskValidation() {
        let projectID = UUID()
        let first = ProjectTask(projectId: projectID, title: "First")
        let second = ProjectTask(projectId: projectID, parentTaskId: first.id, title: "Second")
        let board = TaskBoard(tasks: [first, second])
        #expect(board.canLinkTask(second.id, to: first.id))
        #expect(!board.canLinkTask(first.id, to: second.id))
        #expect(!board.canLinkTask(first.id, to: first.id))
        #expect(!board.canLinkTask(first.id, to: UUID()))
    }

    @Test("Parent choices group by story and search titles or story names")
    func parentTaskGroups() {
        let projectID = UUID()
        let design = ProjectStory(projectId: projectID, title: "Design")
        let build = ProjectStory(projectId: projectID, title: "Build")
        let first = ProjectTask(projectId: projectID, storyId: design.id, title: "Draw mockups")
        let second = ProjectTask(projectId: projectID, storyId: build.id, title: "Draw components")
        let ungrouped = ProjectTask(projectId: projectID, title: "Publish")
        let child = ProjectTask(projectId: projectID, parentTaskId: first.id, title: "Current task")
        let board = TaskBoard(stories: [design, build], tasks: [first, second, ungrouped, child])

        let groups = board.parentTaskGroups(for: child.id)
        #expect(groups.map { $0.story?.title } == ["Design", "Build", nil])
        #expect(groups.map { $0.tasks.map(\.title) } == [["Draw mockups"], ["Draw components"], ["Publish"]])
        #expect(board.parentTaskGroups(for: child.id, matching: "design").flatMap(\.tasks).map(\.id) == [first.id])
        #expect(board.parentTaskGroups(for: child.id, matching: "draw").flatMap(\.tasks).map(\.id) == [first.id, second.id])
        #expect(board.parentTaskGroups(for: first.id).flatMap(\.tasks).contains { $0.id == child.id } == false)
    }

}
