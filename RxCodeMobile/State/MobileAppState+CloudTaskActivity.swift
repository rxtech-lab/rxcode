import Foundation
import RxCodeCore
import RxCodeSync

extension MobileAppState {
    func cloudTaskActivity(for task: ProjectTask) -> CloudTaskActivity? {
        guard let remoteID = taskBoard(for: task.projectId).cloudSync?.taskRemoteId(task.id) else { return nil }
        return cloudTaskActivityByProject[task.projectId]?[remoteID]
    }

    func refreshEncryptedTaskActivity(projectID: UUID) async throws {
        guard usesCloudTasks, let cloud = taskCloud, cloud.isSignedIn,
              let remoteID = cloudTaskProjects.first(where: { $0.id == projectID })?.cloudId else { return }
        let accountID = cloud.accountID
        let recipient = identity.publicKeyHex
        let records = try await cloud.taskActivity(projectID: remoteID, recipient: recipient)
        guard cloud.accountID == accountID, identity.publicKeyHex == recipient, usesCloudTasks else { return }
        let trusted = Set(pairedDesktops.map(\.pubkeyHex))
        let deviceIdentity = identity
        let decoded = try await Task.detached {
            try records.filter { trusted.contains($0.envelope.sender) }.map { record in
                try record.envelope.open(identity: deviceIdentity, trustedSenders: trusted,
                    projectID: remoteID, taskID: record.taskId)
            }
        }.value
        guard cloud.accountID == accountID, identity.publicKeyHex == recipient, usesCloudTasks else { return }
        var activities = cloudTaskActivityByProject[projectID] ?? [:]
        for activity in decoded {
            if let existing = activities[activity.taskID], existing.updatedAt > activity.updatedAt { continue }
            activities[activity.taskID] = activity
        }
        let currentTrusted = Set(pairedDesktops.map(\.pubkeyHex))
        cloudTaskActivityByProject[projectID] = activities.filter { currentTrusted.contains($0.value.senderPublicKey) }
        if let snapshot = cloudTaskBoards[projectID] { storeTaskBoardSnapshot(snapshot, cloud: true) }
    }

    func applyingDecryptedTaskActivity(to snapshot: MobileTaskBoardSnapshot) -> MobileTaskBoardSnapshot {
        var board = snapshot.board
        var connections = snapshot.taskLinkedSessions
        for index in board.tasks.indices {
            let id = board.tasks[index].id
            guard let remoteID = board.cloudSync?.taskRemoteId(id),
                  let activity = cloudTaskActivityByProject[snapshot.projectID]?[remoteID],
                  pairedDesktops.contains(where: { $0.pubkeyHex == activity.senderPublicKey }) else { continue }
            board.tasks[index].attentionReason = activity.attentionReason
            connections[id.uuidString] = activity.connections
        }
        return MobileTaskBoardSnapshot(projectID: snapshot.projectID, board: board,
            taskSessionIDs: snapshot.taskSessionIDs, taskLinkedSessions: connections,
            taskCloudIDs: snapshot.taskCloudIDs, classifyingTaskIDs: snapshot.classifyingTaskIDs,
            defaultAgent: snapshot.defaultAgent)
    }

    /// New prompts use the encrypted paired channel; they never enter a plaintext
    /// cloud task mutation. The Mac publishes the resulting history as ciphertext.
    func sendEncryptedCloudTaskFollowUp(_ task: ProjectTask, text: String) async throws {
        guard let activity = cloudTaskActivity(for: task),
              let desktop = pairedDesktops.first(where: { $0.pubkeyHex == activity.senderPublicKey }) else {
            throw AutopilotRemoteError.server("Pair with the Mac that runs this task to send an encrypted follow-up.")
        }
        try await activateDesktop(desktop)
        try await desktopTaskBoardCall(TaskBoardRequestPayload(projectID: activity.sourceProjectID,
            operation: .followUp, taskID: activity.sourceTaskID, text: text))
    }
}
