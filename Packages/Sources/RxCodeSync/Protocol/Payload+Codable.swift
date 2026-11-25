import Foundation
import RxCodeCore

// MARK: - Codable

extension Payload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    enum TypeKey: String {
        case pairRequest = "pair_request"
        case pairAck = "pair_ack"
        case unpair
        case apnsToken = "apns_token"
        case pushToken = "push_token"
        case liveActivityToken = "live_activity_token"
        case requestSnapshot = "request_snapshot"
        case snapshot
        case settingsUpdate = "settings_update"
        case sessionUpdate = "session_update"
        case subscribeSession = "subscribe_session"
        case userMessage = "user_message"
        case cancelStream = "cancel_stream"
        case removeQueuedMessage = "remove_queued_message"
        case queueMessageAction = "queue_message_action"
        case newSessionRequest = "new_session_request"
        case threadActionRequest = "thread_action_request"
        case loadMoreMessages = "load_more_messages"
        case moreMessages = "more_messages"
        case threadChangesRequest = "thread_changes_request"
        case threadChangesResult = "thread_changes_result"
        case remoteFileRequest = "remote_file_request"
        case remoteFileResult = "remote_file_result"
        case briefingContentRequest = "briefing_content_request"
        case briefingContentResult = "briefing_content_result"
        case searchRequest = "search_request"
        case searchResults = "search_results"
        case notification
        case permissionRequest = "permission_request"
        case permissionResponse = "permission_response"
        case questionQueue = "question_queue"
        case questionAnswer = "question_answer"
        case confirmationQueue = "confirmation_queue"
        case confirmationDecision = "confirmation_decision"
        case planDecision = "plan_decision"
        case branchOpRequest = "branch_op_request"
        case branchOpResult = "branch_op_result"
        case folderTreeRequest = "folder_tree_request"
        case folderTreeResult = "folder_tree_result"
        case createProjectRequest = "create_project_request"
        case createProjectResult = "create_project_result"
        case deleteProjectRequest = "delete_project_request"
        case deleteProjectResult = "delete_project_result"
        case runProfileMutationRequest = "run_profile_mutation_request"
        case runProfileResult = "run_profile_result"
        case runProfileRunRequest = "run_profile_run_request"
        case runProfileStopRequest = "run_profile_stop_request"
        case runnableDetectRequest = "runnable_detect_request"
        case runnableDetectResult = "runnable_detect_result"
        case runTaskUpdate = "run_task_update"
        case skillCatalogRequest = "skill_catalog_request"
        case skillCatalogResult = "skill_catalog_result"
        case skillMutationRequest = "skill_mutation_request"
        case skillMutationResult = "skill_mutation_result"
        case skillSourceMutationRequest = "skill_source_mutation_request"
        case skillSourceMutationResult = "skill_source_mutation_result"
        case acpRegistryRequest = "acp_registry_request"
        case acpRegistryResult = "acp_registry_result"
        case acpMutationRequest = "acp_mutation_request"
        case acpMutationResult = "acp_mutation_result"
        case mcpConfigRequest = "mcp_config_request"
        case mcpConfigResult = "mcp_config_result"
        case mcpMutationRequest = "mcp_mutation_request"
        case mcpMutationResult = "mcp_mutation_result"
        case autopilotRequest = "autopilot_request"
        case autopilotResult = "autopilot_result"
        case taskBoardRequest = "task_board_request"
        case taskBoardResult = "task_board_result"
        case taskBoardUpdate = "task_board_update"
        case agentHubUpdate = "agent_hub_update"
        case agentRequest = "agent_request"
        case agentResult = "agent_result"
        case screenShareRequest = "screen_share_request"
        case screenShareState = "screen_share_state"
        case screenFrame = "screen_frame"
        case screenFrameAck = "screen_frame_ack"
        case remoteInput = "remote_input"
        case ping
        case pong
        case iceCandidates = "ice_candidates"
        case iceSelected = "ice_selected"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let kind = TypeKey(rawValue: rawType) else {
            self = .unknown(type: rawType)
            return
        }
        switch kind {
        case .pairRequest: self = .pairRequest(try container.decode(PairRequestPayload.self, forKey: .data))
        case .pairAck: self = .pairAck(try container.decode(PairAckPayload.self, forKey: .data))
        case .unpair: self = .unpair(try container.decode(UnpairPayload.self, forKey: .data))
        case .apnsToken: self = .apnsToken(try container.decode(APNsTokenPayload.self, forKey: .data))
        case .pushToken: self = .pushToken(try container.decode(PushTokenPayload.self, forKey: .data))
        case .liveActivityToken: self = .liveActivityToken(try container.decode(LiveActivityTokenPayload.self, forKey: .data))
        case .requestSnapshot: self = .requestSnapshot(try container.decode(RequestSnapshotPayload.self, forKey: .data))
        case .snapshot: self = .snapshot(try container.decode(SnapshotPayload.self, forKey: .data))
        case .settingsUpdate: self = .settingsUpdate(try container.decode(MobileSettingsUpdatePayload.self, forKey: .data))
        case .sessionUpdate: self = .sessionUpdate(try container.decode(SessionUpdatePayload.self, forKey: .data))
        case .subscribeSession: self = .subscribeSession(try container.decode(SubscribeSessionPayload.self, forKey: .data))
        case .userMessage: self = .userMessage(try container.decode(UserMessagePayload.self, forKey: .data))
        case .cancelStream: self = .cancelStream(try container.decode(CancelStreamPayload.self, forKey: .data))
        case .removeQueuedMessage: self = .removeQueuedMessage(try container.decode(RemoveQueuedMessagePayload.self, forKey: .data))
        case .queueMessageAction: self = .queueMessageAction(try container.decode(QueueMessageActionPayload.self, forKey: .data))
        case .newSessionRequest: self = .newSessionRequest(try container.decode(NewSessionRequestPayload.self, forKey: .data))
        case .threadActionRequest: self = .threadActionRequest(try container.decode(ThreadActionRequestPayload.self, forKey: .data))
        case .loadMoreMessages: self = .loadMoreMessages(try container.decode(LoadMoreMessagesRequestPayload.self, forKey: .data))
        case .moreMessages: self = .moreMessages(try container.decode(MoreMessagesPayload.self, forKey: .data))
        case .threadChangesRequest: self = .threadChangesRequest(try container.decode(ThreadChangesRequestPayload.self, forKey: .data))
        case .threadChangesResult: self = .threadChangesResult(try container.decode(ThreadChangesResultPayload.self, forKey: .data))
        case .remoteFileRequest: self = .remoteFileRequest(try container.decode(RemoteFileRequestPayload.self, forKey: .data))
        case .remoteFileResult: self = .remoteFileResult(try container.decode(RemoteFileResultPayload.self, forKey: .data))
        case .briefingContentRequest: self = .briefingContentRequest(try container.decode(BriefingContentRequestPayload.self, forKey: .data))
        case .briefingContentResult: self = .briefingContentResult(try container.decode(BriefingContentResultPayload.self, forKey: .data))
        case .searchRequest: self = .searchRequest(try container.decode(SearchRequestPayload.self, forKey: .data))
        case .searchResults: self = .searchResults(try container.decode(SearchResultsPayload.self, forKey: .data))
        case .notification: self = .notification(try container.decode(NotificationPayload.self, forKey: .data))
        case .permissionRequest: self = .permissionRequest(try container.decode(PermissionRequestPayload.self, forKey: .data))
        case .permissionResponse: self = .permissionResponse(try container.decode(PermissionResponsePayload.self, forKey: .data))
        case .questionQueue: self = .questionQueue(try container.decode(QuestionQueuePayload.self, forKey: .data))
        case .questionAnswer: self = .questionAnswer(try container.decode(QuestionAnswerPayload.self, forKey: .data))
        case .confirmationQueue: self = .confirmationQueue(try container.decode(ConfirmationQueuePayload.self, forKey: .data))
        case .confirmationDecision: self = .confirmationDecision(try container.decode(ConfirmationDecisionPayload.self, forKey: .data))
        case .planDecision: self = .planDecision(try container.decode(PlanDecisionPayload.self, forKey: .data))
        case .branchOpRequest: self = .branchOpRequest(try container.decode(BranchOpRequestPayload.self, forKey: .data))
        case .branchOpResult: self = .branchOpResult(try container.decode(BranchOpResultPayload.self, forKey: .data))
        case .folderTreeRequest: self = .folderTreeRequest(try container.decode(FolderTreeRequestPayload.self, forKey: .data))
        case .folderTreeResult: self = .folderTreeResult(try container.decode(FolderTreeResultPayload.self, forKey: .data))
        case .createProjectRequest: self = .createProjectRequest(try container.decode(CreateProjectRequestPayload.self, forKey: .data))
        case .createProjectResult: self = .createProjectResult(try container.decode(CreateProjectResultPayload.self, forKey: .data))
        case .deleteProjectRequest: self = .deleteProjectRequest(try container.decode(DeleteProjectRequestPayload.self, forKey: .data))
        case .deleteProjectResult: self = .deleteProjectResult(try container.decode(DeleteProjectResultPayload.self, forKey: .data))
        case .runProfileMutationRequest: self = .runProfileMutationRequest(try container.decode(RunProfileMutationRequestPayload.self, forKey: .data))
        case .runProfileResult: self = .runProfileResult(try container.decode(RunProfileResultPayload.self, forKey: .data))
        case .runProfileRunRequest: self = .runProfileRunRequest(try container.decode(RunProfileRunRequestPayload.self, forKey: .data))
        case .runProfileStopRequest: self = .runProfileStopRequest(try container.decode(RunProfileStopRequestPayload.self, forKey: .data))
        case .runnableDetectRequest: self = .runnableDetectRequest(try container.decode(RunnableDetectRequestPayload.self, forKey: .data))
        case .runnableDetectResult: self = .runnableDetectResult(try container.decode(RunnableDetectResultPayload.self, forKey: .data))
        case .runTaskUpdate: self = .runTaskUpdate(try container.decode(RunTaskUpdatePayload.self, forKey: .data))
        case .skillCatalogRequest: self = .skillCatalogRequest(try container.decode(SkillCatalogRequestPayload.self, forKey: .data))
        case .skillCatalogResult: self = .skillCatalogResult(try container.decode(SkillCatalogResultPayload.self, forKey: .data))
        case .skillMutationRequest: self = .skillMutationRequest(try container.decode(SkillMutationRequestPayload.self, forKey: .data))
        case .skillMutationResult: self = .skillMutationResult(try container.decode(SkillMutationResultPayload.self, forKey: .data))
        case .skillSourceMutationRequest: self = .skillSourceMutationRequest(try container.decode(SkillSourceMutationRequestPayload.self, forKey: .data))
        case .skillSourceMutationResult: self = .skillSourceMutationResult(try container.decode(SkillSourceMutationResultPayload.self, forKey: .data))
        case .acpRegistryRequest: self = .acpRegistryRequest(try container.decode(ACPRegistryRequestPayload.self, forKey: .data))
        case .acpRegistryResult: self = .acpRegistryResult(try container.decode(ACPRegistryResultPayload.self, forKey: .data))
        case .acpMutationRequest: self = .acpMutationRequest(try container.decode(ACPMutationRequestPayload.self, forKey: .data))
        case .acpMutationResult: self = .acpMutationResult(try container.decode(ACPMutationResultPayload.self, forKey: .data))
        case .mcpConfigRequest: self = .mcpConfigRequest(try container.decode(MCPConfigRequestPayload.self, forKey: .data))
        case .mcpConfigResult: self = .mcpConfigResult(try container.decode(MCPConfigResultPayload.self, forKey: .data))
        case .mcpMutationRequest: self = .mcpMutationRequest(try container.decode(MCPMutationRequestPayload.self, forKey: .data))
        case .mcpMutationResult: self = .mcpMutationResult(try container.decode(MCPMutationResultPayload.self, forKey: .data))
        case .autopilotRequest: self = .autopilotRequest(try container.decode(AutopilotRequestPayload.self, forKey: .data))
        case .autopilotResult: self = .autopilotResult(try container.decode(AutopilotResultPayload.self, forKey: .data))
        case .taskBoardRequest: self = .taskBoardRequest(try container.decode(TaskBoardRequestPayload.self, forKey: .data))
        case .taskBoardResult: self = .taskBoardResult(try container.decode(TaskBoardResultPayload.self, forKey: .data))
        case .taskBoardUpdate: self = .taskBoardUpdate(try container.decode(TaskBoardUpdatePayload.self, forKey: .data))
        case .agentHubUpdate: self = .agentHubUpdate(try container.decode(AgentHubUpdatePayload.self, forKey: .data))
        case .agentRequest: self = .agentRequest(try container.decode(AgentRequestPayload.self, forKey: .data))
        case .agentResult: self = .agentResult(try container.decode(AgentResultPayload.self, forKey: .data))
        case .screenShareRequest: self = .screenShareRequest(try container.decode(ScreenShareRequestPayload.self, forKey: .data))
        case .screenShareState: self = .screenShareState(try container.decode(ScreenShareStatePayload.self, forKey: .data))
        case .screenFrame: self = .screenFrame(try container.decode(ScreenFramePayload.self, forKey: .data))
        case .screenFrameAck: self = .screenFrameAck(try container.decode(ScreenFrameAckPayload.self, forKey: .data))
        case .remoteInput: self = .remoteInput(try container.decode(RemoteInputPayload.self, forKey: .data))
        case .ping: self = .ping(try container.decode(PingPayload.self, forKey: .data))
        case .pong: self = .pong(try container.decode(PongPayload.self, forKey: .data))
        case .iceCandidates: self = .iceCandidates(try container.decode(ICECandidatesPayload.self, forKey: .data))
        case .iceSelected: self = .iceSelected(try container.decode(ICESelectedPayload.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pairRequest(let p): try container.encode(TypeKey.pairRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pairAck(let p): try container.encode(TypeKey.pairAck.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unpair(let p): try container.encode(TypeKey.unpair.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .apnsToken(let p): try container.encode(TypeKey.apnsToken.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pushToken(let p): try container.encode(TypeKey.pushToken.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .liveActivityToken(let p): try container.encode(TypeKey.liveActivityToken.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .requestSnapshot(let p): try container.encode(TypeKey.requestSnapshot.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .snapshot(let p): try container.encode(TypeKey.snapshot.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .settingsUpdate(let p): try container.encode(TypeKey.settingsUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .sessionUpdate(let p): try container.encode(TypeKey.sessionUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .subscribeSession(let p): try container.encode(TypeKey.subscribeSession.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .userMessage(let p): try container.encode(TypeKey.userMessage.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .cancelStream(let p): try container.encode(TypeKey.cancelStream.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .removeQueuedMessage(let p): try container.encode(TypeKey.removeQueuedMessage.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .queueMessageAction(let p): try container.encode(TypeKey.queueMessageAction.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .newSessionRequest(let p): try container.encode(TypeKey.newSessionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .threadActionRequest(let p): try container.encode(TypeKey.threadActionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .loadMoreMessages(let p): try container.encode(TypeKey.loadMoreMessages.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .moreMessages(let p): try container.encode(TypeKey.moreMessages.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .threadChangesRequest(let p): try container.encode(TypeKey.threadChangesRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .threadChangesResult(let p): try container.encode(TypeKey.threadChangesResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .remoteFileRequest(let p): try container.encode(TypeKey.remoteFileRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .remoteFileResult(let p): try container.encode(TypeKey.remoteFileResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .briefingContentRequest(let p): try container.encode(TypeKey.briefingContentRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .briefingContentResult(let p): try container.encode(TypeKey.briefingContentResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .searchRequest(let p): try container.encode(TypeKey.searchRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .searchResults(let p): try container.encode(TypeKey.searchResults.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .notification(let p): try container.encode(TypeKey.notification.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionRequest(let p): try container.encode(TypeKey.permissionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionResponse(let p): try container.encode(TypeKey.permissionResponse.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .questionQueue(let p): try container.encode(TypeKey.questionQueue.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .questionAnswer(let p): try container.encode(TypeKey.questionAnswer.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .confirmationQueue(let p): try container.encode(TypeKey.confirmationQueue.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .confirmationDecision(let p): try container.encode(TypeKey.confirmationDecision.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .planDecision(let p): try container.encode(TypeKey.planDecision.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .branchOpRequest(let p): try container.encode(TypeKey.branchOpRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .branchOpResult(let p): try container.encode(TypeKey.branchOpResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .folderTreeRequest(let p): try container.encode(TypeKey.folderTreeRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .folderTreeResult(let p): try container.encode(TypeKey.folderTreeResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .createProjectRequest(let p): try container.encode(TypeKey.createProjectRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .createProjectResult(let p): try container.encode(TypeKey.createProjectResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .deleteProjectRequest(let p): try container.encode(TypeKey.deleteProjectRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .deleteProjectResult(let p): try container.encode(TypeKey.deleteProjectResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runProfileMutationRequest(let p): try container.encode(TypeKey.runProfileMutationRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runProfileResult(let p): try container.encode(TypeKey.runProfileResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runProfileRunRequest(let p): try container.encode(TypeKey.runProfileRunRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runProfileStopRequest(let p): try container.encode(TypeKey.runProfileStopRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runnableDetectRequest(let p): try container.encode(TypeKey.runnableDetectRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runnableDetectResult(let p): try container.encode(TypeKey.runnableDetectResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .runTaskUpdate(let p): try container.encode(TypeKey.runTaskUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .skillCatalogRequest(let p): try container.encode(TypeKey.skillCatalogRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .skillCatalogResult(let p): try container.encode(TypeKey.skillCatalogResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .skillMutationRequest(let p): try container.encode(TypeKey.skillMutationRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .skillMutationResult(let p): try container.encode(TypeKey.skillMutationResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .skillSourceMutationRequest(let p): try container.encode(TypeKey.skillSourceMutationRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .skillSourceMutationResult(let p): try container.encode(TypeKey.skillSourceMutationResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .acpRegistryRequest(let p): try container.encode(TypeKey.acpRegistryRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .acpRegistryResult(let p): try container.encode(TypeKey.acpRegistryResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .acpMutationRequest(let p): try container.encode(TypeKey.acpMutationRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .acpMutationResult(let p): try container.encode(TypeKey.acpMutationResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .mcpConfigRequest(let p): try container.encode(TypeKey.mcpConfigRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .mcpConfigResult(let p): try container.encode(TypeKey.mcpConfigResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .mcpMutationRequest(let p): try container.encode(TypeKey.mcpMutationRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .mcpMutationResult(let p): try container.encode(TypeKey.mcpMutationResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .autopilotRequest(let p): try container.encode(TypeKey.autopilotRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .autopilotResult(let p): try container.encode(TypeKey.autopilotResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .taskBoardRequest(let p): try container.encode(TypeKey.taskBoardRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .taskBoardResult(let p): try container.encode(TypeKey.taskBoardResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .taskBoardUpdate(let p): try container.encode(TypeKey.taskBoardUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .agentHubUpdate(let p): try container.encode(TypeKey.agentHubUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .agentRequest(let p): try container.encode(TypeKey.agentRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .agentResult(let p): try container.encode(TypeKey.agentResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .screenShareRequest(let p): try container.encode(TypeKey.screenShareRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .screenShareState(let p): try container.encode(TypeKey.screenShareState.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .screenFrame(let p): try container.encode(TypeKey.screenFrame.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .screenFrameAck(let p): try container.encode(TypeKey.screenFrameAck.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .remoteInput(let p): try container.encode(TypeKey.remoteInput.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .ping(let p): try container.encode(TypeKey.ping.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pong(let p): try container.encode(TypeKey.pong.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .iceCandidates(let p): try container.encode(TypeKey.iceCandidates.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .iceSelected(let p): try container.encode(TypeKey.iceSelected.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unknown(let type): try container.encode(type, forKey: .type)
        }
    }
}
