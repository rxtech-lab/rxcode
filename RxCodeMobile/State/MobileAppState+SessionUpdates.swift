import Foundation
import RxCodeCore
import RxCodeSync
import SwiftUI
import os.log

extension MobileAppState {
    func applyRunProfileResult(_ result: RunProfileResultPayload) {
        inFlightRunProfileRequests.remove(result.clientRequestID)
        if let profiles = result.profiles {
            runProfilesByProject[result.projectID] = profiles
            logger.info("[RunProfiles] applied result profiles project=\(result.projectID.uuidString, privacy: .public) count=\(profiles.count, privacy: .public)")
        }
        if let task = result.task {
            upsertRunTask(task)
        }
        if result.ok {
            lastRunProfileError = nil
            Task { await self.requestSnapshot() }
        } else {
            lastRunProfileError = result.errorMessage ?? String(localized: "Run profile operation failed.")
        }
    }

    func applyRunnableDetectResult(_ result: RunnableDetectResultPayload) {
        runnableDetectInFlight.remove(result.projectID)
        if pendingRunnableDetectRequestID == result.clientRequestID {
            pendingRunnableDetectRequestID = nil
        }
        if result.ok, let detected = result.detected {
            detectedRunnablesByProject[result.projectID] = detected
            runnableDetectError = nil
            logger.info("[RunProfiles] applied detection project=\(result.projectID.uuidString, privacy: .public) xcode=\(detected.xcode.count, privacy: .public) npm=\(detected.npm.count, privacy: .public) make=\(detected.make.count, privacy: .public)")
        } else {
            runnableDetectError = result.errorMessage ?? String(localized: "Failed to detect runnables.")
        }
    }

    func applySkillCatalogResult(_ result: SkillCatalogResultPayload) {
        guard pendingSkillCatalogRequestID == result.clientRequestID else { return }
        pendingSkillCatalogRequestID = nil
        skillCatalogLoading = false
        if result.ok {
            skillCatalog = result.plugins
            skillSources = result.sources
            skillCatalogError = nil
        } else {
            skillCatalogError = result.errorMessage ?? String(localized: "Failed to load skills.")
        }
    }

    func applySkillMutationResult(_ result: SkillMutationResultPayload) {
        inFlightSkillMutations.remove(result.pluginID)
        skillCatalog = result.plugins
        skillSources = result.sources
        if result.ok {
            lastSkillError = nil
        } else {
            lastSkillError = result.errorMessage ?? String(localized: "Skill operation failed.")
        }
    }

    func applySkillSourceMutationResult(_ result: SkillSourceMutationResultPayload) {
        if let key = skillSourceMutationKeys.removeValue(forKey: result.clientRequestID) {
            inFlightSkillSourceMutations.remove(key)
        }
        if let sourceID = result.sourceID {
            inFlightSkillSourceMutations.remove(sourceID)
        }
        skillCatalog = result.plugins
        skillSources = result.sources
        if result.ok {
            lastSkillError = nil
        } else {
            lastSkillError = result.errorMessage ?? String(localized: "Skill source operation failed.")
        }
    }

    func applyACPRegistryResult(_ result: ACPRegistryResultPayload) {
        guard pendingACPRegistryRequestID == result.clientRequestID else { return }
        pendingACPRegistryRequestID = nil
        acpRegistryLoading = false
        if result.ok {
            acpRegistryAgents = result.registryAgents
            acpInstalledClients = result.installedClients
            acpRegistryError = nil
        } else {
            acpRegistryError = result.errorMessage ?? String(localized: "Failed to load the agent registry.")
        }
    }

    func applyACPMutationResult(_ result: ACPMutationResultPayload) {
        if let key = acpMutationKeys.removeValue(forKey: result.clientRequestID) {
            inFlightACPMutations.remove(key)
        }
        acpRegistryAgents = result.registryAgents
        acpInstalledClients = result.installedClients
        if result.ok {
            lastACPError = nil
        } else {
            lastACPError = result.errorMessage ?? String(localized: "Agent operation failed.")
        }
    }

    func applyMCPConfigResult(_ result: MCPConfigResultPayload) {
        guard pendingMCPConfigRequestID == result.clientRequestID else { return }
        pendingMCPConfigRequestID = nil
        mcpConfigLoading = false
        if result.ok {
            mcpServers = result.servers
            mcpConfigError = nil
        } else {
            mcpConfigError = result.errorMessage ?? String(localized: "Failed to load MCP servers.")
        }
    }

    func applyMCPMutationResult(_ result: MCPMutationResultPayload) {
        inFlightMCPMutations.remove(result.serverName)
        mcpServers = result.servers
        if result.ok {
            lastMCPError = nil
        } else {
            lastMCPError = result.errorMessage ?? String(localized: "MCP operation failed.")
        }
    }

    func upsertRunTask(_ task: MobileRunTaskSnapshot) {
        if let idx = runTasks.firstIndex(where: { $0.taskId == task.taskId }) {
            runTasks[idx] = task
        } else {
            runTasks.insert(task, at: 0)
        }
        runTasks.sort { $0.startedAt > $1.startedAt }
    }

    func applySessionUpdate(_ update: SessionUpdatePayload) {
        if let previous = update.previousSessionID, previous != update.sessionID {
            sessionIDRedirects[previous] = update.sessionID
            for (stale, target) in sessionIDRedirects where target == previous {
                sessionIDRedirects[stale] = update.sessionID
            }
            if let carried = messagesBySession.removeValue(forKey: previous) {
                if let existing = messagesBySession[update.sessionID], !existing.isEmpty {
                    // The new session id already accumulated live messages
                    // before the redirect landed. Prepend the carried history,
                    // deduped by id, so the older messages aren't dropped.
                    let existingIDs = Set(existing.map(\.id))
                    messagesBySession[update.sessionID] =
                        carried.filter { !existingIDs.contains($0.id) } + existing
                } else {
                    messagesBySession[update.sessionID] = carried
                }
            }
            if sessionsWithMoreMessages.remove(previous) != nil {
                sessionsWithMoreMessages.insert(update.sessionID)
            }
            if loadingMoreSessions.remove(previous) != nil {
                loadingMoreSessions.insert(update.sessionID)
            }
            if loadingThreadMessageSessions.remove(previous) != nil {
                loadingThreadMessageSessions.insert(update.sessionID)
            }
            if activeSessionID == previous {
                activeSessionID = update.sessionID
            }
            sessions.removeAll { $0.id == previous }
        }

        if let summary = update.summary {
            upsertSessionSummary(summary)
        } else if let isStreaming = update.isStreaming {
            updateSessionStreamingFlag(sessionID: update.sessionID, isStreaming: isStreaming)
        }

        if let isThinking = update.isThinking {
            setSessionThinking(sessionID: update.sessionID, isThinking: isThinking)
        }
        // A session that is no longer streaming cannot still be thinking.
        if update.isStreaming == false {
            setSessionThinking(sessionID: update.sessionID, isThinking: false)
        }

        if update.fileEditsChanged == true,
           activeSessionID == update.sessionID || threadChanges?.sessionID == update.sessionID {
            Task { [weak self] in
                await self?.requestThreadChanges(sessionID: update.sessionID)
            }
        }

        switch update.kind {
        case .messageAppended:
            if let m = update.message {
                messagesBySession[update.sessionID, default: []].append(m)
            }
        case .messageUpdated:
            if let m = update.message,
               var list = messagesBySession[update.sessionID],
               let idx = list.firstIndex(where: { $0.id == m.id }),
               list[idx] != m {
                list[idx] = m
                messagesBySession[update.sessionID] = list
            }
        case .streamingFinished:
            setSessionThinking(sessionID: update.sessionID, isThinking: false)
            // Soft success cue, but only when the user is actually looking at
            // (or last looked at) the session that just finished. Avoids
            // buzzing on background-session completions.
            if update.sessionID == activeSessionID {
                MobileHaptics.streamFinished()
            }
        case .streamingStarted, .statusChanged:
            // Surface as a flag on the relevant session row.
            break
        }
    }

    func upsertSessionSummary(_ summary: SessionSummary) {
        var updated = sessions
        if let index = updated.firstIndex(where: { $0.id == summary.id }) {
            guard updated[index] != summary else { return }
            updated[index] = summary
        } else {
            updated.append(summary)
        }
        updated.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
        sessions = updated
    }

    func updateSessionStreamingFlag(sessionID: String, isStreaming: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = sessions[index]
        guard current.isStreaming != isStreaming else { return }
        sessions[index] = SessionSummary(
            id: current.id,
            projectId: current.projectId,
            title: current.title,
            updatedAt: current.updatedAt,
            isPinned: current.isPinned,
            isArchived: current.isArchived,
            isStreaming: isStreaming,
            attention: current.attention,
            progress: current.progress,
            todos: current.todos,
            queuedMessages: current.queuedMessages,
            hasUncheckedCompletion: current.hasUncheckedCompletion,
            parentThreadId: current.parentThreadId,
            threadLabel: current.threadLabel,
            changedFileCount: current.changedFileCount
        )
    }

    func setSessionThinking(sessionID: String, isThinking: Bool) {
        guard thinkingSessions.contains(sessionID) != isThinking else { return }
        if isThinking {
            thinkingSessions.insert(sessionID)
        } else {
            thinkingSessions.remove(sessionID)
        }
    }
}
