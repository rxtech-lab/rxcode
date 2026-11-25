import Foundation
import RxCodeCore
import RxCodeSync

extension AppState {
    func sendAgentHub(to peer: String) async {
        guard agentHubLoaded, !mobileSyncObservers.isEmpty, MobileSyncService.shared.isPairedPeer(peer) else { return }
        let agents = agentProfiles.map { profile in
            let conversation = agentConversationSummary(profile)
            return AgentHubAgent(profile: profile, modelLabel: resolvedAgentConfig(profile).model ?? "Workspace Default",
                primarySessionId: conversation?.id, lastActivityAt: conversation?.updatedAt,
                isStreaming: conversation.flatMap { sessionStates[$0.id]?.isStreaming } ?? false,
                isUsingComputer: agentComputerUseActivity[profile.id] != nil)
        }
        let hub = AgentHubSnapshot(agents: agents, memory: agentMemoryNotes, jobs: agentJobs,
            schedules: scheduledTasks.filter { $0.agentId != nil }, remoteAccess: agentRemoteAccess,
            canCaptureScreen: ComputerControl.hasScreenRecordingAccess, canControlInput: ComputerControl.hasAccessibilityAccess())
        MobileSyncService.shared.agentHubSyncSeq &+= 1
        await MobileSyncService.shared.send(.agentHubUpdate(.init(snapshot: hub, seq: MobileSyncService.shared.agentHubSyncSeq)), toHex: peer)
    }

    func scheduleAgentHubBroadcast() {
        guard agentHubBroadcastTask == nil, !mobileSyncObservers.isEmpty else { return }
        agentHubBroadcastTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            agentHubBroadcastTask = nil
            for device in MobileSyncService.shared.pairedDevices { await sendAgentHub(to: device.pubkeyHex) }
        }
    }

    func handleAgentPayload(_ payload: RxCodeSync.Payload, from peer: String) async {
        guard !mobileSyncObservers.isEmpty, MobileSyncService.shared.isPairedPeer(peer) else { return }
        switch payload {
        case .screenShareRequest(let request): await screenShareService.handle(request, from: peer)
        case .screenFrameAck(let ack): screenShareService.acknowledge(ack, from: peer)
        case .remoteInput(let event): screenShareService.input(event, from: peer)
        case .agentRequest(let request):
            if request.operation == .refresh { await sendAgentHub(to: peer); return }
            let result: AgentResultPayload
            do {
                result = try await performPhoneAgentRequest(request)
            } catch {
                result = .init(clientRequestID: request.clientRequestID, ok: false, error: error.localizedDescription, agentID: request.agentID)
            }
            guard MobileSyncService.shared.isPairedPeer(peer) else { return }
            await MobileSyncService.shared.send(.agentResult(result), toHex: peer)
            await sendAgentHub(to: peer)
        default: break
        }
    }

    /// Applies one agent change or message from a paired phone.
    private func performPhoneAgentRequest(_ request: AgentRequestPayload) async throws -> AgentResultPayload {
        switch request.operation {
        case .createAgent:
            guard let profile = request.agent, agentProfile(id: profile.id) == nil else {
                throw AgentHubError.sendFailed(String(localized: "The phone sent an invalid agent."))
            }
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentHubError.sendFailed(String(localized: "Give the agent a name."))
            }
            var agent = profile
            // A phone's copy can't carry the Mac's conversation links.
            agent.primarySessionId = nil
            agent.phoneMessages = []
            agent.createdAt = .now
            let saved = upsertAgent(agent)
            return .init(clientRequestID: request.clientRequestID, ok: true, agentID: saved.id)
        case .updateAgent:
            guard let profile = request.agent, agentProfile(id: profile.id) != nil else { throw AgentHubError.unknownAgent }
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentHubError.sendFailed(String(localized: "Give the agent a name."))
            }
            let saved = upsertAgent(profile)
            return .init(clientRequestID: request.clientRequestID, ok: true, agentID: saved.id)
        case .deleteAgent:
            guard let id = request.agentID, agentProfile(id: id) != nil else { throw AgentHubError.unknownAgent }
            await deleteAgent(id: id)
            return .init(clientRequestID: request.clientRequestID, ok: true, agentID: id)
        case .sendMessage:
            guard let id = request.agentID, agentProfile(id: id) != nil else { throw AgentHubError.unknownAgent }
            let session = try await sendMessageToAgent(id, text: request.text ?? "")
            return .init(clientRequestID: request.clientRequestID, ok: true, agentID: id, sessionID: session)
        case .openConversation:
            guard let id = request.agentID, let agent = agentProfile(id: id) else { throw AgentHubError.unknownAgent }
            return .init(clientRequestID: request.clientRequestID, ok: true, agentID: id,
                         sessionID: agentConversationSummary(agent)?.id)
        default:
            throw AgentHubError.sendFailed(String(localized: "Unsupported phone action."))
        }
    }
}
