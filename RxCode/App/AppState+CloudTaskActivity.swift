import Foundation
import RxCodeCore
import RxCodeSync
import RxAuthSwift

extension AppState {
    /// Uploads only authenticated ciphertext, addressed to the Mac and its paired devices.
    /// Re-pairing changes the recipient fingerprint and re-encrypts existing history.
    func publishEncryptedTaskActivity(projectID: UUID, cloudID: String, sync: CloudBoardSyncState) async throws {
        let accountID = rxAuth.user?.id
        let service = MobileSyncService.shared
        let recipients = service.pairedDevices.map(\.pubkeyHex)
        let identity = service.identity
        for task in taskBoard(for: projectID).tasks {
            guard let remoteID = sync.taskRemoteId(task.id),
                  task.sessionKey != nil || task.attentionReason != nil else { continue }
            if task.sessionKey != nil, chatSessionId(for: task) == nil { continue }
            let messages = await taskRunMessages(for: task) ?? []
            let connections = await mobileTaskLinkedSessions(for: task)
            let updatedAt = max(task.updatedAt, messages.last?.timestamp ?? task.updatedAt,
                allSessionSummaries.filter { connections.map(\.id).contains($0.id) }.map(\.updatedAt).max() ?? task.updatedAt)
            let activity = CloudTaskActivity(projectID: cloudID, taskID: remoteID, updatedAt: updatedAt,
                sourceProjectID: projectID, sourceTaskID: task.id, senderPublicKey: identity.publicKeyHex, sessionID: chatSessionId(for: task),
                runs: TaskRunTurn.turns(from: messages), connections: connections, attentionReason: task.attentionReason)
            let fingerprint = try await Task.detached {
                try EncryptedTaskActivity.fingerprint(activity, recipients: recipients + [identity.publicKeyHex])
            }.value
            let cacheKey = "cloudTaskActivity.v1.\(accountID ?? "").\(cloudID).\(remoteID).\(identity.publicKeyHex)"
            guard UserDefaults.standard.string(forKey: cacheKey) != fingerprint else { continue }
            let envelope = try await Task.detached {
                try EncryptedTaskActivity.seal(activity, identity: identity, recipientKeys: recipients)
            }.value
            guard rxAuth.user?.id == accountID, service.pairedDevices.map(\.pubkeyHex).sorted() == recipients.sorted() else { return }
            try await projectCloud.saveTaskActivity(projectId: cloudID, taskId: remoteID, envelope: envelope)
            UserDefaults.standard.set(fingerprint, forKey: cacheKey)
        }
    }
}
