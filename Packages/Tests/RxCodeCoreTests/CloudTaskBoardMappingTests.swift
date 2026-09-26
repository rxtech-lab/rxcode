import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cloud task board projection")
struct CloudTaskBoardMappingTests {
    @Test func keepsNavigationIdentityAndResolvesStoryAndParent() {
        let projectID = UUID()
        let remote = CloudRemoteBoard(
            stories: [CloudRemoteStory(id: "story", fields: CloudStoryFields(title: "Story"))],
            tasks: [
                CloudRemoteTask(id: "child", fields: CloudTaskFields(title: "Child", type: "Custom", storyId: "story", parentTaskId: "parent")),
                CloudRemoteTask(id: "parent", fields: CloudTaskFields(title: "Parent", assignedDeviceId: "mac")),
            ])
        let first = TaskBoard().replacingCloudRows(remote, projectID: projectID)
        let second = first.replacingCloudRows(remote, projectID: projectID)
        #expect(first.tasks.map(\.id) == second.tasks.map(\.id))
        #expect(first.stories.map(\.id) == second.stories.map(\.id))
        #expect(second.tasks[0].storyId == second.stories[0].id)
        #expect(second.tasks[0].parentTaskId == second.tasks[1].id)
        #expect(second.itemType(id: second.tasks[0].typeId)?.name == "Custom")
        #expect(second.tasks[1].assignedDeviceId == "mac")
        #expect(!second.canLinkTask(second.tasks[1].id, to: second.tasks[0].id))
    }

    @Test func remoteDeletionRemovesLinksAndKeepsSavedViews() {
        let projectID = UUID()
        var board = TaskBoard().replacingCloudRows(CloudRemoteBoard(tasks: [CloudRemoteTask(id: "t", fields: CloudTaskFields(title: "Task"))]), projectID: projectID)
        let view = TaskSavedView(name: "My View")
        board.savedViews = [view]
        let empty = board.replacingCloudRows(CloudRemoteBoard(), projectID: projectID)
        #expect(empty.tasks.isEmpty)
        #expect(empty.cloudSync?.tasks.isEmpty == true)
        #expect(empty.savedViews.map(\.id) == [view.id])
    }
}
