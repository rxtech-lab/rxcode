import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cloud laptop assignment")
struct CloudLaptopAssignmentTests {
    @Test func oldBoardsDecodeWithoutAssignment() throws {
        let old = Data(#"{"title":"Existing task","id":"791044C4-B8A2-4399-97C4-E59087AE2A5A"}"#.utf8)
        #expect(try JSONDecoder().decode(ProjectTask.self, from: old).assignedDeviceId == nil)
        #expect(try JSONDecoder().decode(CloudTaskFields.self, from: old).assignedDeviceId == nil)
    }

    @Test func assignmentSurvivesDesktopMergeAndCanBeCleared() throws {
        let board = TaskBoard()
        let task = ProjectTask(projectId: UUID(), title: "Task")
        let fields = CloudTaskFields(title: "Task", assignedDeviceId: "laptop")
        let pulled = board.applying(fields, to: task, sync: CloudBoardSyncState(), updatedAt: nil)
        #expect(pulled.assignedDeviceId == "laptop")
        #expect(board.cloudFields(for: pulled, sync: CloudBoardSyncState()).assignedDeviceId == "laptop")
        let cleared = board.applying(CloudTaskFields(title: "Task"), to: pulled, sync: CloudBoardSyncState(), updatedAt: nil)
        #expect(cleared.assignedDeviceId == nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudTaskFields(title: "Task"))) as! [String: Any]
        #expect(object["assignedDeviceId"] is NSNull)
    }
}
