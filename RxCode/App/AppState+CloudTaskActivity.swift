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
            let cacheKey = "cloudTaskActivity.v1.\(accountID ?? "").\(cloudID).\(remoteID).\(identity.publicKeyHex)"
            // Cheap pre-check: this runs on every 30s board poll, and building
            // the activity means fully parsing the task's transcripts. Skip the
            // parse when nothing feeding the activity has changed since the
            // last successful publish.
            let sourceKey = "cloudTaskActivitySource.v1.\(accountID ?? "").\(cloudID).\(remoteID).\(identity.publicKeyHex)"
            let source = await taskActivitySourceSignature(for: task, recipients: recipients)
            if UserDefaults.standard.string(forKey: sourceKey) == source,
               UserDefaults.standard.string(forKey: cacheKey) != nil {
                continue
            }
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
            guard UserDefaults.standard.string(forKey: cacheKey) != fingerprint else {
                UserDefaults.standard.set(source, forKey: sourceKey)
                continue
            }
            let envelope = try await Task.detached {
                try EncryptedTaskActivity.seal(activity, identity: identity, recipientKeys: recipients)
            }.value
            guard rxAuth.user?.id == accountID, service.pairedDevices.map(\.pubkeyHex).sorted() == recipients.sorted() else { return }
            try await projectCloud.saveTaskActivity(projectId: cloudID, taskId: remoteID, envelope: envelope)
            UserDefaults.standard.set(fingerprint, forKey: cacheKey)
            UserDefaults.standard.set(source, forKey: sourceKey)
        }
    }

    /// A signature of everything a task's cloud activity is built from, cheap
    /// to compute: task fields, the linked threads' summaries, their live
    /// in-memory message counts, and each transcript file's size and mtime.
    /// A missing transcript yields a stable "missing" entry, so threads with
    /// no jsonl aren't re-probed every poll.
    private func taskActivitySourceSignature(for task: ProjectTask, recipients: [String]) async -> String {
        let runID = task.sessionKey.map(resolveCurrentSessionId)
        let sourceID = task.sourceSessionKey.map(resolveCurrentSessionId)
        let linked = allSessionSummaries.filter { summary in
            summary.id == runID || summary.id == sourceID ||
                summary.parentThreadId.map { resolveCurrentSessionId($0) == runID } == true
        }.sorted { $0.id < $1.id }

        var parts: [String] = [
            "t=\(task.updatedAt.timeIntervalSince1970)",
            "a=\(task.attentionReason ?? "")",
            "run=\(runID ?? "")",
            "src=\(sourceID ?? "")",
            "r=\(recipients.sorted().joined(separator: ","))",
        ]
        for summary in linked {
            let live = sessionStates[summary.id]
            var part = "\(summary.id)|\(summary.updatedAt.timeIntervalSince1970)|\(summary.threadLabel ?? summary.title)"
            part += "|live=\(live?.messages.count ?? -1):\(live?.messages.last?.blocks.count ?? 0):\(live?.isStreaming == true)"
            if summary.origin == .cliBacked,
               let project = projects.first(where: { $0.id == summary.projectId }) {
                if let url = await cliStore.resolveExistingJsonlURL(sid: summary.id, cwd: project.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    part += "|f=\(size):\(mtime)"
                } else {
                    part += "|f=missing"
                }
            }
            parts.append(part)
        }
        return parts.joined(separator: "\n")
    }
}
