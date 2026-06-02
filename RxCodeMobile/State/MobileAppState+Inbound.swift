import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI
import UIKit
import os.log
extension MobileAppState {
    // MARK: - Inbound events

    func handle(_ event: RelayClient.Event) {
        switch event {
        case .stateChanged(let state):
            logger.info("[Relay] connection state changed: \(String(describing: state), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public)")
            let previous = connectionState
            connectionState = state
            triggerConnectionFeedback(from: previous, to: state)
            if case .connected = state, isPaired {
                Task { await self.requestSnapshot(reason: "relay_connected") }
            }
        case .deliveryFailed(let toHex):
            logger.warning("[Relay] delivery failed to desktopKey=\(String(toHex.prefix(12)), privacy: .public)")
        case .inbound(let inbound):
            handleInbound(inbound)
        }
    }

    func handleInbound(_ inbound: RelayClient.Inbound) {
        switch inbound.payload {
        case .pairAck(let ack):
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            if ack.accepted {
                upsertPairedDesktop(
                    PairedDesktop(
                        pubkeyHex: inbound.fromHex,
                        displayName: ack.desktopName,
                        pairedAt: .now,
                        lastSeen: .now,
                        relayURL: relayURL.absoluteString
                    )
                )
                setActiveDesktop(pubkeyHex: inbound.fromHex)
                pairingStatus = .idle
                logger.info("[Pairing] accepted desktop=\(ack.desktopName, privacy: .public) desktopKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public)")
                MobileHaptics.connected()
                savePairedDesktops()
                Task {
                    await self.requestSnapshot()
                    await self.reportAPNsTokenIfPending()
                }
            } else {
                failPairing(String(localized: "Your Mac declined the pairing request."))
            }
        case .unpair:
            guard let desktop = pairedDesktops.first(where: { $0.pubkeyHex == inbound.fromHex }) else { return }
            Task { await self.removePairedDesktopAfterRemoteUnpair(desktop) }
        case .snapshot(let snap):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "snapshot") else { return }
            // Drop out-of-order snapshots so a delayed older snapshot doesn't
            // overwrite a fresher one that already landed. The desktop stamps
            // `seq` monotonically per send; legacy desktops send `nil` and we
            // accept those unconditionally (no sequencing to enforce).
            if let incoming = snap.seq {
                if let applied = lastAppliedSnapshotSeq, incoming <= applied {
                    logger.warning("[MobileSync] dropped stale snapshot seq=\(incoming, privacy: .public) lastApplied=\(applied, privacy: .public) from desktopKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                    return
                }
                lastAppliedSnapshotSeq = incoming
            }
            let profileProjectCount = snap.runProfiles?.count ?? 0
            let profileTotal = snap.runProfiles?.reduce(0) { $0 + $1.profiles.count } ?? 0
            logger.info("[MobileSync] applying snapshot seq=\(snap.seq ?? 0, privacy: .public) projects=\(snap.projects.count, privacy: .public) sessions=\(snap.sessions.count, privacy: .public) runProfileProjects=\(profileProjectCount, privacy: .public) runProfileTotal=\(profileTotal, privacy: .public) runTasks=\(snap.runTasks?.count ?? 0, privacy: .public) from desktopKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            projects = snap.projects
            sessions = snap.sessions
            branchBriefings = snap.branchBriefings ?? []
            threadSummaries = snap.threadSummaries ?? []
            ciStatusByProject = Dictionary(uniqueKeysWithValues: (snap.ciStatuses ?? []).map { ($0.projectId, $0.status) })
            desktopSettings = snap.settings
            desktopUsage = snap.usage
            desktopHostMetrics = snap.hostMetrics
            desktopWebProxy = snap.webProxy
            if let webProxy = snap.webProxy {
                logger.info("[WebBrowserSync] snapshot web proxy host=\(webProxy.host, privacy: .public) port=\(webProxy.port, privacy: .public)")
            } else {
                logger.warning("[WebBrowserSync] snapshot missing web proxy info")
            }
            if let runProfiles = snap.runProfiles {
                runProfilesByProject = Dictionary(
                    uniqueKeysWithValues: runProfiles.map { ($0.projectId, $0.profiles) }
                )
            }
            if let tasks = snap.runTasks {
                runTasks = tasks.sorted { $0.startedAt > $1.startedAt }
            }
            if let branches = snap.projectBranches {
                projectBranches = Dictionary(uniqueKeysWithValues: branches.map { ($0.projectId, $0.currentBranch) })
                availableBranchesByProject = Dictionary(
                    uniqueKeysWithValues: branches.compactMap { info -> (UUID, [String])? in
                        guard let list = info.availableBranches else { return nil }
                        return (info.projectId, list)
                    }
                )
            }
            if let active = snap.activeSessionID {
                if let messages = snap.activeSessionMessages {
                    // The snapshot carries only the most recent page; replacing
                    // the window resets paging to that page. Guard against the
                    // pathological case where an empty page arrives for a
                    // session we already have content for — never clobber a
                    // populated thread with []. (Seq-drop above handles the
                    // common stale-snapshot case; this is a belt-and-suspenders
                    // guard for any future code path that might send [].)
                    let existing = messagesBySession[active]?.count ?? 0
                    if !messages.isEmpty || existing == 0 {
                        messagesBySession[active] = messages
                        if snap.activeSessionHasMore == true {
                            sessionsWithMoreMessages.insert(active)
                        } else {
                            sessionsWithMoreMessages.remove(active)
                        }
                        loadingMoreSessions.remove(active)
                    } else {
                        logger.warning("[MobileSync] refused to overwrite \(existing) messages with empty page for session=\(active, privacy: .public)")
                    }
                } else if messagesBySession[active] == nil {
                    messagesBySession[active] = []
                }
                loadingThreadMessageSessions.remove(active)
                // The snapshot's activeSessionID is metadata that labels the
                // carried activeSessionMessages — it must not be treated as a
                // navigation command. Only adopt it when our local selection
                // is the optimistic draft id produced by startNewSession and
                // we're waiting for the desktop to assign a real id; otherwise
                // a reconnect-driven snapshot would yank the user out of the
                // thread they're currently reading.
                if let current = activeSessionID, MobileDraftSessionID.isDraft(current) {
                    activeSessionID = active
                }
            }
            hasReceivedInitialSnapshot = true
            refreshWidgetData()
        case .moreMessages(let page):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "more_messages") else { return }
            applyMoreMessages(page)
        case .sessionUpdate(let update):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "session_update") else { return }
            applySessionUpdate(update)
            refreshWidgetData()
        case .permissionRequest(let req):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "permission_request") else { return }
            pendingPermission = req
            MobileHaptics.attentionNeeded()
        case .questionQueue(let queue):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "question_queue") else { return }
            let grew = queue.questions.count > pendingQuestions.count
            pendingQuestions = queue.questions
            if grew { MobileHaptics.attentionNeeded() }
        case .notification:
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "notification") else { return }
            // Foreground notifications arriving over WS — iOS won't show a
            // banner automatically; UI surfaces these in a toast/badge.
            break
        case .searchResults(let results):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "search_results") else { return }
            guard let pending = pendingSearchID, results.clientRequestID == pending else { return }
            searchProjectIDs = results.projectIDs
            searchThreadHits = results.threadHits
            isSearching = false
        case .threadChangesResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "thread_changes_result") else { return }
            guard let pending = pendingThreadChangesID, result.clientRequestID == pending else { return }
            pendingThreadChangesID = nil
            isLoadingThreadChanges = false
            threadChanges = result
        case .remoteFileResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "remote_file_result") else { return }
            guard let pending = pendingRemoteFileID, result.clientRequestID == pending else { return }
            pendingRemoteFileID = nil
            isLoadingRemoteFile = false
            remoteFileResult = result
        case .branchOpResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "branch_op_result") else { return }
            inFlightBranchOps.remove(result.clientRequestID)
            if !result.ok {
                lastBranchOpError = result.errorMessage ?? String(localized: "Branch operation failed.")
            }
        case .folderTreeResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "folder_tree_result") else { return }
            guard pendingFolderTreeRequestID == result.clientRequestID else { return }
            pendingFolderTreeRequestID = nil
            remoteFolderIsLoading = false
            if result.ok, let root = result.root {
                remoteFolderRoot = root
                remoteFolderError = nil
            } else {
                remoteFolderError = result.errorMessage ?? String(localized: "Failed to load folders.")
            }
        case .createProjectResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "create_project_result") else { return }
            guard pendingCreateProjectRequestID == result.clientRequestID else { return }
            pendingCreateProjectRequestID = nil
            remoteProjectCreateInFlight = false
            if result.ok, let project = result.project {
                if !projects.contains(where: { $0.id == project.id }) {
                    projects.append(project)
                }
                lastCreatedProjectID = project.id
                remoteProjectCreateError = nil
                Task { await self.requestSnapshot() }
            } else {
                remoteProjectCreateError = result.errorMessage ?? String(localized: "Failed to add project.")
            }
        case .deleteProjectResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "delete_project_result") else { return }
            guard pendingDeleteProjectRequestID == result.clientRequestID else { return }
            pendingDeleteProjectRequestID = nil
            if result.ok {
                // Already removed optimistically; ensure it's gone and reconcile.
                projects.removeAll { $0.id == result.projectID }
                sessions.removeAll { $0.projectId == result.projectID }
                remoteProjectDeleteError = nil
                Task { await self.requestSnapshot() }
            } else {
                remoteProjectDeleteError = result.errorMessage ?? String(localized: "Failed to delete project.")
                // Restore the project the desktop refused to delete.
                Task { await self.requestSnapshot() }
            }
        case .runProfileResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "run_profile_result") else { return }
            logger.info("[RunProfiles] received result id=\(result.clientRequestID.uuidString, privacy: .public) ok=\(result.ok, privacy: .public) project=\(result.projectID.uuidString, privacy: .public) profiles=\(result.profiles?.count ?? 0, privacy: .public) task=\(result.task?.taskId.uuidString ?? "<nil>", privacy: .public) error=\(result.errorMessage ?? "<nil>", privacy: .public)")
            applyRunProfileResult(result)
        case .runTaskUpdate(let update):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "run_task_update") else { return }
            upsertRunTask(update.task)
        case .runnableDetectResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "runnable_detect_result") else { return }
            applyRunnableDetectResult(result)
        case .skillCatalogResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "skill_catalog_result") else { return }
            applySkillCatalogResult(result)
        case .skillMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "skill_mutation_result") else { return }
            applySkillMutationResult(result)
        case .skillSourceMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "skill_source_mutation_result") else { return }
            applySkillSourceMutationResult(result)
        case .acpRegistryResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "acp_registry_result") else { return }
            applyACPRegistryResult(result)
        case .acpMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "acp_mutation_result") else { return }
            applyACPMutationResult(result)
        case .mcpConfigResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "mcp_config_result") else { return }
            applyMCPConfigResult(result)
        case .mcpMutationResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "mcp_mutation_result") else { return }
            applyMCPMutationResult(result)
        case .autopilotResult(let result):
            guard acceptsActiveDesktopPayload(from: inbound.fromHex, type: "autopilot_result") else { return }
            if let continuation = pendingAutopilotRequests.removeValue(forKey: result.clientRequestID) {
                continuation.resume(returning: result)
            }
        case .ping:
            guard pairedDesktops.contains(where: { $0.pubkeyHex == inbound.fromHex }) else { return }
            Task { try? await self.client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

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
            thinkingSessions.remove(update.sessionID)
        }

        switch update.kind {
        case .messageAppended:
            if let m = update.message {
                messagesBySession[update.sessionID, default: []].append(m)
            }
        case .messageUpdated:
            if let m = update.message,
               var list = messagesBySession[update.sessionID],
               let idx = list.firstIndex(where: { $0.id == m.id }) {
                list[idx] = m
                messagesBySession[update.sessionID] = list
            }
        case .streamingFinished:
            thinkingSessions.remove(update.sessionID)
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
        if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }
        sessions.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func updateSessionStreamingFlag(sessionID: String, isStreaming: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = sessions[index]
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
            hasUncheckedCompletion: current.hasUncheckedCompletion
        )
    }

    func setSessionThinking(sessionID: String, isThinking: Bool) {
        if isThinking {
            thinkingSessions.insert(sessionID)
        } else {
            thinkingSessions.remove(sessionID)
        }
    }

    func refreshFromDesktop(reason: String) async {
        await requestSnapshot(reason: reason)
    }

    func requestSnapshot(reason: String = "manual") async {
        guard isPaired else {
            logger.info("[MobileSync] snapshot request skipped reason=\(reason, privacy: .public): mobile is not paired")
            return
        }
        let payload = RequestSnapshotPayload(activeSessionID: activeSessionID)
        do {
            try await client.send(.requestSnapshot(payload), toHex: pairedDesktopPubkey)
            logger.info("[MobileSync] requested snapshot reason=\(reason, privacy: .public) activeSession=\(self.activeSessionID ?? "<nil>", privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[MobileSync] snapshot request failed reason=\(reason, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func failPairing(_ message: String) {
        pairingStatus = .failed(message)
        MobileHaptics.connectionError()
    }

    func triggerConnectionFeedback(
        from previous: RelayClient.ConnectionState,
        to next: RelayClient.ConnectionState
    ) {
        guard previous != next else { return }
        guard isPaired, pairingStatus != .inProgress else { return }

        switch next {
        case .connected:
            if case .reconnecting = previous {
                MobileHaptics.connected()
            }
        case .reconnecting:
            if previous == .connected {
                MobileHaptics.connectionError()
            }
        case .disconnected:
            if previous == .connected {
                MobileHaptics.connectionError()
            }
        case .connecting:
            break
        }
    }

    func reportAPNsTokenIfPending() async {
        guard !pairedDesktops.isEmpty else {
            logger.info("[APNs] token report pending: mobile is not paired")
            return
        }
        guard let tokenHex = apnsTokenHex else {
            logger.info("[APNs] token report pending: no APNs token yet")
            return
        }
        guard let env = apnsEnvironment else {
            logger.info("[APNs] token report pending: no APNs environment yet")
            return
        }
        let payload = APNsTokenPayload(tokenHex: tokenHex, environment: env)
        for desktop in pairedDesktops {
            do {
                try await client.send(.apnsToken(payload), toHex: desktop.pubkeyHex)
                logger.info("[APNs] token reported to desktop tokenPrefix=\(String(tokenHex.prefix(12)), privacy: .public) environment=\(env, privacy: .public) desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            } catch {
                logger.error("[APNs] token report failed desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public) mobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applySettingsUpdateLocally(_ update: MobileSettingsUpdatePayload) {
        guard let current = desktopSettings else { return }
        // Optimistically reflect a provider change, resolving its display name
        // from the synced options so the picker label updates immediately.
        let summarizationProvider = update.summarizationProvider ?? current.summarizationProvider
        let summarizationProviderDisplayName = update.summarizationProvider.flatMap { raw in
            current.availableSummarizationProviders?.first(where: { $0.id == raw })?.displayName
        } ?? current.summarizationProviderDisplayName
        desktopSettings = MobileSettingsSnapshot(
            selectedAgentProvider: update.selectedAgentProvider ?? current.selectedAgentProvider,
            selectedModel: update.selectedModel ?? current.selectedModel,
            selectedACPClientId: update.selectedACPClientId ?? current.selectedACPClientId,
            selectedEffort: update.selectedEffort ?? current.selectedEffort,
            permissionMode: update.permissionMode ?? current.permissionMode,
            summarizationProvider: summarizationProvider,
            summarizationProviderDisplayName: summarizationProviderDisplayName,
            openAISummarizationEndpoint: current.openAISummarizationEndpoint,
            openAISummarizationModel: update.openAISummarizationModel ?? current.openAISummarizationModel,
            notificationsEnabled: update.notificationsEnabled ?? current.notificationsEnabled,
            focusMode: update.focusMode ?? current.focusMode,
            autoArchiveEnabled: update.autoArchiveEnabled ?? current.autoArchiveEnabled,
            archiveRetentionDays: update.archiveRetentionDays ?? current.archiveRetentionDays,
            autoPreviewSettings: update.autoPreviewSettings ?? current.autoPreviewSettings,
            availableEfforts: current.availableEfforts,
            availableModels: current.availableModels,
            modelSections: current.modelSections,
            availableSummarizationProviders: current.availableSummarizationProviders,
            openAISummarizationModels: current.openAISummarizationModels
        )
    }
}
