import Foundation
import Testing
@testable import RxCodeCore

@Suite("Card assignees and permissions")
struct CardAssigneeTests {
    @Test func legacyCardsRemainReadable() throws {
        let data = Data(#"{"title":"Legacy"}"#.utf8)
        #expect(try JSONDecoder().decode(ProjectTask.self, from: data).assigneeIds.isEmpty)
        #expect(try JSONDecoder().decode(ProjectStory.self, from: data).assigneeIds.isEmpty)
    }

    @Test func cloudRoundTripPreservesAssignees() throws {
        let projectID = UUID()
        let remote = try JSONDecoder().decode(CloudRemoteBoard.self, from: Data(#"{"stories":[{"id":"story","title":"Story","assigneeIds":["member"]}],"tasks":[{"id":"task","title":"Task","assigneeIds":["member"],"storyId":"story"}],"members":[{"userId":"member","name":"Member","image":"https://example.com/avatar.png"}],"role":"member","currentUserId":"member"}"#.utf8))
        let board = TaskBoard().replacingCloudRows(remote, projectID: projectID)
        #expect(board.tasks[0].assigneeIds == ["member"])
        #expect(board.stories[0].assigneeProfiles.first?.name == "Member")
        #expect(board.cloudFields(for: board.tasks[0], sync: board.cloudSync!).assigneeIds == ["member"])
        let saved = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        #expect(saved.tasks[0].assigneeProfiles.first?.image == "https://example.com/avatar.png")
        #expect(saved.stories[0].assigneeIds == ["member"])
        #expect(saved.cloudSync?.currentUserId == "member")
    }

    @Test func onlyOwnerOrAssigneeCanEditCloudCard() {
        var board = TaskBoard(cloudSync: CloudBoardSyncState())
        #expect(!board.canEditCard(assigneeIds: ["member"], userID: "member"))
        board.cloudSync?.currentUserId = "member"
        board.cloudSync?.role = "member"
        #expect(board.canEditCard(assigneeIds: ["member"], userID: "member"))
        #expect(!board.canEditCard(assigneeIds: ["someone-else"], userID: "member"))
        #expect(!board.canEditCard(assigneeIds: ["other"], userID: "other"))
        board.cloudSync?.role = "owner"
        #expect(board.canEditCard(assigneeIds: [], userID: "member"))
        #expect(!board.canEditCard(assigneeIds: [], userID: nil))
        #expect(TaskBoard().canEditCard(assigneeIds: [], userID: nil))
    }
}
