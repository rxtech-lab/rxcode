import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

extension MobileSyncService {

    // MARK: - Event dispatch

    func handle(event: RelayClient.Event) {
        switch event {
        case .stateChanged(let s):
            connectionState = s
            logger.info("[MobileSync] relay state=\(String(describing: s), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public)")
        case .deliveryFailed(let toHex):
            // Drop-on-offline policy — desktop ignores, mobile will resync on
            // next reconnect.
            logger.warning("[MobileSync] relay delivery failed to mobileKey=\(String(toHex.prefix(12)), privacy: .public)")
        case .inbound(let inbound):
            handleInbound(inbound)
        }
    }

    /// Handle events from a specific relay server (multi-relay support).
    func handle(event: RelayClient.Event, forServer server: SavedRelayServer) {
        switch event {
        case .stateChanged(let s):
            relayConnectionStates[server.id] = s
            // Update global connectionState to reflect aggregate status
            updateAggregateConnectionState()
            logger.info("[MobileSync] relay state=\(String(describing: s), privacy: .public) server=\(server.name, privacy: .public)")
        case .deliveryFailed(let toHex):
            logger.warning("[MobileSync] relay delivery failed to mobileKey=\(String(toHex.prefix(12)), privacy: .public) server=\(server.name, privacy: .public)")
        case .inbound(let inbound):
            handleInbound(inbound, fromServer: server)
        }
    }

    /// Update aggregate connection state based on all relay states.
    private func updateAggregateConnectionState() {
        let states = Array(relayConnectionStates.values)
        if states.isEmpty {
            connectionState = .disconnected
        } else if states.contains(.connected) {
            connectionState = .connected
        } else if states.contains(.connecting) {
            connectionState = .connecting
        } else if let reconnecting = states.first(where: {
            if case .reconnecting = $0 { return true }
            return false
        }) {
            connectionState = reconnecting
        } else {
            connectionState = .disconnected
        }
    }

    /// Handle inbound messages from a specific relay server.
    private func handleInbound(_ inbound: RelayClient.Inbound, fromServer server: SavedRelayServer) {
        // Route to standard handler but track which server the message came from
        // This allows pairing to know which relay was used
        if case .pairRequest = inbound.payload {
            pairingRelayServerID = server.id
        }
        handleInbound(inbound, viaClient: additionalClients[server.id])
    }

    func handleInbound(_ inbound: RelayClient.Inbound) {
        handleInbound(inbound, viaClient: nil)
    }

    private func handleInbound(_ inbound: RelayClient.Inbound, viaClient: SyncClient?) {
        let activeClient = viaClient ?? client
        switch inbound.payload {
        case .pairRequest(let req):
            pendingPairing = req
            Task { try? await activeClient.addPeer(req.mobilePubkeyHex) }
        case .unpair:
            guard isPairedPeer(inbound.fromHex) else { return }
            handleRemoteUnpair(pubkeyHex: inbound.fromHex)
        case .apnsToken(let t):
            if let idx = pairedDevices.firstIndex(where: { $0.pubkeyHex == inbound.fromHex }) {
                logger.info("[APNs] token received mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public) environment=\(t.environment, privacy: .public)")
                pairedDevices[idx].apnsToken = t.tokenHex
                pairedDevices[idx].apnsEnvironment = t.environment
                pairedDevices[idx].lastSeen = .now
                for staleIdx in pairedDevices.indices where staleIdx != idx && pairedDevices[staleIdx].apnsToken == t.tokenHex {
                    logger.warning("[APNs] clearing duplicate token from stale mobileKey=\(String(self.pairedDevices[staleIdx].pubkeyHex.prefix(12)), privacy: .public) currentMobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public)")
                    pairedDevices[staleIdx].apnsToken = nil
                    pairedDevices[staleIdx].apnsEnvironment = nil
                }
                savePairedDevices()
            } else {
                logger.warning("[APNs] token received for unknown mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public) environment=\(t.environment, privacy: .public)")
            }
        case .liveActivityToken(let t):
            guard let idx = pairedDevices.firstIndex(where: { $0.pubkeyHex == inbound.fromHex }) else {
                logger.warning("[LiveActivity] token received for unknown mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                return
            }
            if let startToken = t.pushToStartTokenHex, !startToken.isEmpty {
                pairedDevices[idx].liveActivityStartToken = startToken
                logger.info("[LiveActivity] push-to-start token registered mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            }
            if t.activityDismissed == true {
                // The user swiped the aggregate Live Activity away. Forget
                // this device's update token; once no device tracks the
                // activity the next job push-to-starts a fresh one.
                if var refs = pairedDevices[idx].liveActivityTokens {
                    refs.removeAll { t.activityID == nil || $0.activityID == t.activityID }
                    pairedDevices[idx].liveActivityTokens = refs.isEmpty ? nil : refs
                }
                if !hasAnyActivityToken {
                    jobsActivityLocallyStarted = false
                    lastPushedJobsSignature = ""
                    cancelJobsActivityStart()
                    pendingJobsPushTask?.cancel()
                    pendingJobsPushTask = nil
                }
                logger.info("[LiveActivity] aggregate activity dismissed by user activity=\(t.activityID ?? "<nil>", privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            } else if t.activityStartedLocally == true {
                // A foregrounded device started the activity itself with
                // `Activity.request` and reported it the instant it was
                // created — long before APNs mints the update token. Cancel
                // the deferred push-to-start so iOS never spawns a duplicate.
                jobsActivityLocallyStarted = true
                cancelJobsActivityStart()
                logger.info("[LiveActivity] device started aggregate activity locally mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) — deferred push-to-start cancelled")
            } else if let activityToken = t.activityTokenHex, !activityToken.isEmpty,
                      let activityID = t.activityID {
                cancelJobsActivityStart()
                if trackedJobs.isEmpty {
                    // This (fresh) desktop process tracks no jobs, yet the
                    // device still has a job activity registered — it is an
                    // orphan left behind by a previous desktop session that
                    // crashed or quit mid-job and never delivered the
                    // finishing update. End it so it doesn't sit stuck on
                    // "Working" forever, and drop the now-dead token.
                    logger.info("[LiveActivity] activity token from device with no tracked jobs — ending orphaned activity activity=\(activityID, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                    sendJobsActivityEnd(deviceToken: activityToken, device: pairedDevices[idx])
                    pairedDevices[idx].liveActivityTokens = nil
                } else {
                    // One aggregate activity per device — replace any prior token.
                    pairedDevices[idx].liveActivityTokens = [
                        LiveActivityTokenRef(activityID: activityID, token: activityToken)
                    ]
                    logger.info("[LiveActivity] aggregate activity token registered activity=\(activityID, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                    // Push the latest known state straight away so a freshly
                    // started activity isn't left blank until the next change.
                    pendingJobsPushTask?.cancel()
                    pendingJobsPushTask = nil
                    lastPushedJobsSignature = jobsSignature
                    lastJobsPushDate = Date()
                    sendJobsActivityUpdate(staleAfter: allJobsDone ? 8 * 3600 : 3600)
                }
            }
            pairedDevices[idx].lastSeen = .now
            savePairedDevices()
        case .requestSnapshot(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "request_snapshot") else { return }
            logger.info("[MobileSync] snapshot requested by mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) activeSession=\(req.activeSessionID ?? "<nil>", privacy: .public)")
            // AppState owns the data; it observes pendingSnapshotRequests
            // and replies. Stub for now — wired up by AppState bridge.
            var userInfo: [String: Any] = ["from": inbound.fromHex]
            userInfo["activeSessionID"] = req.activeSessionID
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: userInfo
            )
        case .settingsUpdate(let update):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "settings_update") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncSettingsUpdateReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": update]
            )
        case .userMessage(let msg):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "user_message") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncUserMessageReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": msg]
            )
        case .cancelStream(let cancel):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "cancel_stream") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncCancelStreamRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": cancel]
            )
        case .removeQueuedMessage(let payload):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "remove_queued_message") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncRemoveQueuedRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": payload]
            )
        case .newSessionRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "new_session_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncNewSessionRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .threadActionRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "thread_action_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncThreadActionRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .loadMoreMessages(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "load_more_messages") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncLoadMoreMessagesRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .searchRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "search_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncSearchRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .threadChangesRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "thread_changes_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncThreadChangesRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .subscribeSession(let sub):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "subscribe_session") else { return }
            subscribedSessions[inbound.fromHex] = sub.sessionID ?? ""
            var userInfo: [String: Any] = ["from": inbound.fromHex]
            userInfo["activeSessionID"] = sub.sessionID
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: userInfo
            )
        case .permissionResponse(let resp):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "permission_response") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncPermissionResponse,
                object: nil,
                userInfo: ["payload": resp]
            )
        case .questionAnswer(let answer):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "question_answer") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncQuestionAnswerReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": answer]
            )
        case .planDecision(let decision):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "plan_decision") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncPlanDecisionReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": decision]
            )
        case .branchOpRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "branch_op_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncBranchOpRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .folderTreeRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "folder_tree_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncFolderTreeRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .createProjectRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "create_project_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncCreateProjectRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runProfileMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "run_profile_mutation_request") else { return }
            logger.info("[MobileSync] run profile mutation requested operation=\(req.operation.rawValue, privacy: .public) project=\(req.projectID.uuidString, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunProfileMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runProfileRunRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "run_profile_run_request") else { return }
            logger.info("[MobileSync] run profile start requested project=\(req.projectID.uuidString, privacy: .public) profile=\(req.profileID.uuidString, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunProfileRunRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runProfileStopRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "run_profile_stop_request") else { return }
            logger.info("[MobileSync] run profile stop requested task=\(req.taskID?.uuidString ?? "<nil>", privacy: .public) project=\(req.projectID?.uuidString ?? "<nil>", privacy: .public) profile=\(req.profileID?.uuidString ?? "<nil>", privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunProfileStopRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runnableDetectRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "runnable_detect_request") else { return }
            logger.info("[MobileSync] runnable detection requested project=\(req.projectID.uuidString, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunnableDetectRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .skillCatalogRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "skill_catalog_request") else { return }
            logger.info("[MobileSync] skill catalog requested forceRefresh=\(req.forceRefresh, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncSkillCatalogRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .skillMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "skill_mutation_request") else { return }
            logger.info("[MobileSync] skill mutation requested operation=\(req.operation.rawValue, privacy: .public) plugin=\(req.pluginID, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncSkillMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .skillSourceMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "skill_source_mutation_request") else { return }
            logger.info("[MobileSync] skill source mutation requested operation=\(req.operation.rawValue, privacy: .public) source=\(req.sourceID ?? req.gitURL ?? "<nil>", privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncSkillSourceMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .acpRegistryRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "acp_registry_request") else { return }
            logger.info("[MobileSync] acp registry requested forceRefresh=\(req.forceRefresh, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncACPRegistryRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .acpMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "acp_mutation_request") else { return }
            logger.info("[MobileSync] acp mutation requested operation=\(req.operation.rawValue, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncACPMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .mcpConfigRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "mcp_config_request") else { return }
            logger.info("[MobileSync] mcp config requested mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncMCPConfigRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .mcpMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "mcp_mutation_request") else { return }
            logger.info("[MobileSync] mcp mutation requested operation=\(req.operation.rawValue, privacy: .public) server=\(req.serverName, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncMCPMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .ping:
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "ping") else { return }
            Task { try? await activeClient.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

    func isPairedPeer(_ pubkeyHex: String) -> Bool {
        pairedDevices.contains { $0.pubkeyHex == pubkeyHex }
    }

    func acceptPairedOnlyPayload(from pubkeyHex: String, type: String) -> Bool {
        guard isPairedPeer(pubkeyHex) else {
            logger.warning("[MobileSync] rejecting \(type, privacy: .public) from unknown mobileKey=\(String(pubkeyHex.prefix(12)), privacy: .public)")
            Task {
                try? await client.addPeer(pubkeyHex)
                try? await client.send(.unpair(UnpairPayload(reason: "unknown_peer")), toHex: pubkeyHex)
                await client.removePeer(pubkeyHex)
            }
            return false
        }
        return true
    }

    func handleRemoteUnpair(pubkeyHex: String) {
        guard pairedDevices.contains(where: { $0.pubkeyHex == pubkeyHex }) else {
            Task { await client.removePeer(pubkeyHex) }
            return
        }

        pairedDevices.removeAll { $0.pubkeyHex == pubkeyHex }
        savePairedDevices()
        subscribedSessions.removeValue(forKey: pubkeyHex)
        logger.info("[MobileSync] removed paired device after remote unpair")
        Task { await client.removePeer(pubkeyHex) }
    }

    /// Send a payload to a single peer (used by AppState when replying to
    /// `request_snapshot` etc).
    func send(_ payload: Payload, toHex hex: String) async {
        let targetClient = clientForPeer(hex)
        do {
            try await targetClient.send(payload, toHex: hex)
            logger.debug("[MobileSync] sent type=\(payload.logName, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[MobileSync] send failed type=\(payload.logName, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
