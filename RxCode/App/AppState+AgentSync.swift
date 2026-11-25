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
                guard let id = request.agentID, agentProfile(id: id) != nil else { throw AgentHubError.unknownAgent }
                guard request.operation == .sendMessage else { throw AgentHubError.sendFailed("Unsupported phone action.") }
                let session = try await sendMessageToAgent(id, text: request.text ?? "")
                result = .init(clientRequestID: request.clientRequestID, ok: true, agentID: id, sessionID: session)
            } catch {
                result = .init(clientRequestID: request.clientRequestID, ok: false, error: error.localizedDescription, agentID: request.agentID)
            }
            guard MobileSyncService.shared.isPairedPeer(peer) else { return }
            await MobileSyncService.shared.send(.agentResult(result), toHex: peer)
            await sendAgentHub(to: peer)
        default: break
        }
    }
}
