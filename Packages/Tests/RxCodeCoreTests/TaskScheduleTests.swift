import Foundation
import Testing
@testable import RxCodeCore

@Suite("Card schedule fields")
struct TaskScheduleTests {
    private let reviewer = CardAssignee(userId: "reviewer", name: "Reviewer")

    @Test func legacyCardsDecodeWithoutScheduleFields() throws {
        let data = Data(#"{"title":"Legacy","size":"huge"}"#.utf8)
        let task = try JSONDecoder().decode(ProjectTask.self, from: data)
        #expect(task.deadline == nil)
        #expect(task.size == nil)
        #expect(task.delays.isEmpty)
        #expect(task.reviewer == nil)
        let story = try JSONDecoder().decode(ProjectStory.self, from: data)
        #expect(story.size == nil)
        #expect(story.delays.isEmpty)
    }

    @Test func reviewerIsWhoeverMovesReviewToDone() {
        let board = TaskBoard()
        var task = ProjectTask(projectId: UUID(), title: "Ship", status: .pendingReview)

        task.status = .done
        task = board.stampingReviewer(task, from: .pendingReview, actor: reviewer)
        #expect(task.reviewer == reviewer)

        task.status = .inProgress
        task = board.stampingReviewer(task, from: .done, actor: reviewer)
        #expect(task.reviewer == nil)

        task.reviewer = reviewer
        task.status = .done
        task = board.stampingReviewer(task, from: .inProgress, actor: reviewer)
        #expect(task.reviewer == nil, "Reaching done without review records no reviewer")
    }

    @Test func unchangedStatusKeepsReviewer() {
        var task = ProjectTask(projectId: UUID(), title: "Ship", status: .done)
        task.reviewer = reviewer
        #expect(TaskBoard().stampingReviewer(task, from: .done, actor: nil).reviewer == reviewer)
    }

    @Test func newDelaysTakeTheActorAsAuthor() {
        let recorded = TaskDelay(reason: "Old", author: CardAssignee(userId: "someone"))
        let stamped = [recorded, TaskDelay(reason: "New")].stampingAuthors(reviewer)
        #expect(stamped[0].author?.userId == "someone")
        #expect(stamped[1].author == reviewer)
    }

    @Test func cloudRoundTripPreservesScheduleFields() throws {
        let projectID = UUID()
        let remote = try JSONDecoder().decode(CloudRemoteBoard.self, from: Data(#"""
        {"tasks":[{"id":"task","title":"Task","status":"done","deadline":"2026-11-02T10:00:00.000Z","size":"l",
          "delays":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","reason":"Blocked","createdAt":"2026-10-28T09:00:00.000Z","authorId":"member"}],
          "reviewerId":"member"}],
         "stories":[{"id":"story","title":"Story","deadline":1793000000000,"size":"xs","delays":[]}],
         "members":[{"userId":"member","name":"Member"}],"role":"owner","currentUserId":"member"}
        """#.utf8))
        let board = TaskBoard().replacingCloudRows(remote, projectID: projectID)
        let task = try #require(board.tasks.first)
        #expect(task.size == .l)
        #expect(task.deadline == CloudDate.parse("2026-11-02T10:00:00Z"))
        #expect(task.delays.first?.author?.name == "Member")
        #expect(task.reviewer?.name == "Member")
        #expect(board.stories.first?.deadline == Date(timeIntervalSince1970: 1_793_000_000))

        // The local card maps back to exactly the fields the server sent, so a
        // synced board is in sync rather than pushing a change.
        let sync = try #require(board.cloudSync)
        #expect(board.cloudFields(for: task, sync: sync) == remote.tasks[0].fields)
        #expect(board.cloudFields(for: board.stories[0]) == remote.stories[0].fields)

        let encoded = try JSONEncoder().encode(remote.tasks[0].fields)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["deadline"] as? String == "2026-11-02T10:00:00Z")
        let delays = try #require(json["delays"] as? [[String: Any]])
        #expect(delays.first?["id"] as? String == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
    }

    @Test func subSecondDeadlinesCompareEqualAfterRoundTrip() throws {
        let deadline = Date(timeIntervalSince1970: 1_793_000_000.4567)
        let fields = CloudTaskFields(title: "Task", deadline: deadline)
        let decoded = try JSONDecoder().decode(CloudTaskFields.self, from: JSONEncoder().encode(fields))
        #expect(decoded == fields)
    }
}
