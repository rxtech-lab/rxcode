import XCTest
import CryptoKit
import RxCodeCore
import RxCodeSync
@testable import RxCodeMobile

@MainActor
final class MobileTaskReviewSyncTests: XCTestCase {
    func testDecryptedCloudHistoryPopulatesPendingCardAndRuns() {
        let state = MobileAppState()
        state.usesCloudTasks = true
        let desktop = DeviceIdentity(privateKey: .init())
        state.pairedDesktops = [PairedDesktop(pubkeyHex: desktop.publicKeyHex, displayName: "Mac", pairedAt: Date())]
        let projectID = UUID()
        let board = TaskBoard().replacingCloudRows(CloudRemoteBoard(tasks: [
            CloudRemoteTask(id: "remote", fields: CloudTaskFields(title: "Task", status: "pending"))
        ]), projectID: projectID)
        let runs = [TaskRunTurn(id: 0, prompt: "Follow-up", response: "Agent response", didError: false)]
        let review = MobileTaskLinkedSession(id: "review", title: "Review", kind: .review, feedback: "Missing tests")
        let activity = CloudTaskActivity(projectID: "cloud", taskID: "remote", updatedAt: Date(),
            sourceProjectID: UUID(), sourceTaskID: UUID(), senderPublicKey: desktop.publicKeyHex,
            sessionID: "chat", runs: runs, connections: [review], attentionReason: "Missing tests")
        state.cloudTaskActivityByProject[projectID] = ["remote": activity]
        state.storeTaskBoardSnapshot(MobileTaskBoardSnapshot(projectID: projectID, board: board), cloud: true)
        let task = state.taskBoard(for: projectID).tasks[0]
        XCTAssertEqual(task.attentionReason, "Missing tests")
        XCTAssertEqual(state.cloudTaskActivity(for: task)?.runs, runs)
        XCTAssertEqual(state.taskLinkedSessions(task), [review])
        state.clearCloudTasks()
        XCTAssertTrue(state.cloudTaskActivityByProject.isEmpty)
        state.taskCacheSaveTask?.cancel()
    }

    func testDesktopRejectionAppearsOnCloudPendingCardAndSurvivesRefresh() {
        let state = MobileAppState()
        let cloudProjectID = UUID()
        let desktopProjectID = UUID()
        let fields = CloudTaskFields(title: "Task", status: TaskStatus.pending.rawValue)
        let cloudBoard = TaskBoard().replacingCloudRows(
            CloudRemoteBoard(tasks: [CloudRemoteTask(id: "remote-task", fields: fields)]), projectID: cloudProjectID)
        let cloudTaskID = cloudBoard.tasks[0].id
        let cloud = MobileTaskBoardSnapshot(projectID: cloudProjectID, board: cloudBoard)
        state.storeTaskBoardSnapshot(cloud, cloud: true)

        var desktopTask = ProjectTask(projectId: desktopProjectID, title: "Task", status: .pending,
                                      attentionReason: "**Review rejected:** validation is missing.")
        let review = MobileTaskLinkedSession(id: "review", title: "Completion Check", kind: .review,
                                            feedback: desktopTask.attentionReason)
        func desktopSnapshot() -> MobileTaskBoardSnapshot {
            MobileTaskBoardSnapshot(projectID: desktopProjectID, board: TaskBoard(tasks: [desktopTask]),
                taskLinkedSessions: [desktopTask.id.uuidString: [review]],
                taskCloudIDs: [desktopTask.id.uuidString: "remote-task"])
        }
        // This is the same ingestion method the inbound taskBoardUpdate uses.
        state.storeTaskBoardSnapshot(desktopSnapshot(), cloud: false)
        XCTAssertEqual(state.cloudTaskBoards[cloudProjectID]?.board.tasks[0].id, cloudTaskID)
        XCTAssertEqual(state.cloudTaskBoards[cloudProjectID]?.board.tasks[0].attentionReason, desktopTask.attentionReason)
        XCTAssertEqual(state.cloudTaskBoards[cloudProjectID]?.taskLinkedSessions[cloudTaskID.uuidString], [review])

        // A fresh server response has no Mac-owned attentionReason.
        state.storeTaskBoardSnapshot(cloud, cloud: true)
        XCTAssertEqual(state.cloudTaskBoards[cloudProjectID]?.board.tasks[0].attentionReason, desktopTask.attentionReason)

        desktopTask.attentionReason = nil
        state.storeTaskBoardSnapshot(desktopSnapshot(), cloud: false)
        XCTAssertNil(state.cloudTaskBoards[cloudProjectID]?.board.tasks[0].attentionReason)
        state.taskCacheSaveTask?.cancel()
    }

    func testReviewArrivingDuringCloudMoveUpdatesDeferredSnapshot() {
        let state = MobileAppState()
        let projectID = UUID()
        let board = TaskBoard().replacingCloudRows(CloudRemoteBoard(tasks: [
            CloudRemoteTask(id: "task", fields: CloudTaskFields(title: "Task"))
        ]), projectID: projectID)
        state.taskMovesInFlight[projectID] = 1
        state.storeTaskBoardSnapshot(MobileTaskBoardSnapshot(projectID: projectID, board: board), cloud: true)
        let task = ProjectTask(projectId: UUID(), title: "Task", attentionReason: "Review feedback")
        state.storeTaskBoardSnapshot(MobileTaskBoardSnapshot(projectID: task.projectId, board: TaskBoard(tasks: [task]),
            taskCloudIDs: [task.id.uuidString: "task"]), cloud: false)
        XCTAssertEqual(state.deferredCloudTaskBoardSnapshots[projectID]?.board.tasks[0].attentionReason, "Review feedback")
        state.taskCacheSaveTask?.cancel()
    }
}
