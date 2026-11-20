import Foundation
import RxCodeCore

/// All plaintext payloads exchanged between paired devices.
///
/// Encoded as a tagged JSON object with `type` as the discriminator so adding
/// new cases stays forward-compatible. Unknown cases decode to
/// `.unknown(type:)` rather than failing the entire envelope decode.
public enum Payload: Sendable {
    case pairRequest(PairRequestPayload)
    case pairAck(PairAckPayload)
    case unpair(UnpairPayload)
    case apnsToken(APNsTokenPayload)
    case pushToken(PushTokenPayload)
    case liveActivityToken(LiveActivityTokenPayload)
    case requestSnapshot(RequestSnapshotPayload)
    case snapshot(SnapshotPayload)
    case settingsUpdate(MobileSettingsUpdatePayload)
    case sessionUpdate(SessionUpdatePayload)
    case subscribeSession(SubscribeSessionPayload)
    case userMessage(UserMessagePayload)
    case cancelStream(CancelStreamPayload)
    case removeQueuedMessage(RemoveQueuedMessagePayload)
    case queueMessageAction(QueueMessageActionPayload)
    case newSessionRequest(NewSessionRequestPayload)
    case threadActionRequest(ThreadActionRequestPayload)
    case loadMoreMessages(LoadMoreMessagesRequestPayload)
    case moreMessages(MoreMessagesPayload)
    case threadChangesRequest(ThreadChangesRequestPayload)
    case threadChangesResult(ThreadChangesResultPayload)
    case remoteFileRequest(RemoteFileRequestPayload)
    case remoteFileResult(RemoteFileResultPayload)
    case briefingContentRequest(BriefingContentRequestPayload)
    case briefingContentResult(BriefingContentResultPayload)
    case searchRequest(SearchRequestPayload)
    case searchResults(SearchResultsPayload)
    case notification(NotificationPayload)
    case permissionRequest(PermissionRequestPayload)
    case permissionResponse(PermissionResponsePayload)
    case questionQueue(QuestionQueuePayload)
    case questionAnswer(QuestionAnswerPayload)
    case confirmationQueue(ConfirmationQueuePayload)
    case confirmationDecision(ConfirmationDecisionPayload)
    case planDecision(PlanDecisionPayload)
    case branchOpRequest(BranchOpRequestPayload)
    case branchOpResult(BranchOpResultPayload)
    case folderTreeRequest(FolderTreeRequestPayload)
    case folderTreeResult(FolderTreeResultPayload)
    case createProjectRequest(CreateProjectRequestPayload)
    case createProjectResult(CreateProjectResultPayload)
    case deleteProjectRequest(DeleteProjectRequestPayload)
    case deleteProjectResult(DeleteProjectResultPayload)
    case runProfileMutationRequest(RunProfileMutationRequestPayload)
    case runProfileResult(RunProfileResultPayload)
    case runProfileRunRequest(RunProfileRunRequestPayload)
    case runProfileStopRequest(RunProfileStopRequestPayload)
    case runnableDetectRequest(RunnableDetectRequestPayload)
    case runnableDetectResult(RunnableDetectResultPayload)
    case runTaskUpdate(RunTaskUpdatePayload)
    case skillCatalogRequest(SkillCatalogRequestPayload)
    case skillCatalogResult(SkillCatalogResultPayload)
    case skillMutationRequest(SkillMutationRequestPayload)
    case skillMutationResult(SkillMutationResultPayload)
    case skillSourceMutationRequest(SkillSourceMutationRequestPayload)
    case skillSourceMutationResult(SkillSourceMutationResultPayload)
    case acpRegistryRequest(ACPRegistryRequestPayload)
    case acpRegistryResult(ACPRegistryResultPayload)
    case acpMutationRequest(ACPMutationRequestPayload)
    case acpMutationResult(ACPMutationResultPayload)
    case mcpConfigRequest(MCPConfigRequestPayload)
    case mcpConfigResult(MCPConfigResultPayload)
    case mcpMutationRequest(MCPMutationRequestPayload)
    case mcpMutationResult(MCPMutationResultPayload)
    case autopilotRequest(AutopilotRequestPayload)
    case autopilotResult(AutopilotResultPayload)
    case taskBoardRequest(TaskBoardRequestPayload)
    case taskBoardResult(TaskBoardResultPayload)
    case taskBoardUpdate(TaskBoardUpdatePayload)
    case ping(PingPayload)
    case pong(PongPayload)
    // Direct-path (P2P) signaling — exchanged over the relay, consumed inside
    // `PeerConnectionManager`, never surfaced to the app layer. See ICEPayloads.swift.
    case iceCandidates(ICECandidatesPayload)
    case iceSelected(ICESelectedPayload)
    case unknown(type: String)
}

public extension Payload {
    var logName: String {
        switch self {
        case .pairRequest: return "pair_request"
        case .pairAck: return "pair_ack"
        case .unpair: return "unpair"
        case .apnsToken: return "apns_token"
        case .pushToken: return "push_token"
        case .liveActivityToken: return "live_activity_token"
        case .requestSnapshot: return "request_snapshot"
        case .snapshot: return "snapshot"
        case .settingsUpdate: return "settings_update"
        case .sessionUpdate: return "session_update"
        case .subscribeSession: return "subscribe_session"
        case .userMessage: return "user_message"
        case .cancelStream: return "cancel_stream"
        case .removeQueuedMessage: return "remove_queued_message"
        case .queueMessageAction: return "queue_message_action"
        case .newSessionRequest: return "new_session_request"
        case .threadActionRequest: return "thread_action_request"
        case .loadMoreMessages: return "load_more_messages"
        case .moreMessages: return "more_messages"
        case .threadChangesRequest: return "thread_changes_request"
        case .threadChangesResult: return "thread_changes_result"
        case .remoteFileRequest: return "remote_file_request"
        case .remoteFileResult: return "remote_file_result"
        case .briefingContentRequest: return "briefing_content_request"
        case .briefingContentResult: return "briefing_content_result"
        case .searchRequest: return "search_request"
        case .searchResults: return "search_results"
        case .notification: return "notification"
        case .permissionRequest: return "permission_request"
        case .permissionResponse: return "permission_response"
        case .questionQueue: return "question_queue"
        case .questionAnswer: return "question_answer"
        case .confirmationQueue: return "confirmation_queue"
        case .confirmationDecision: return "confirmation_decision"
        case .planDecision: return "plan_decision"
        case .branchOpRequest: return "branch_op_request"
        case .branchOpResult: return "branch_op_result"
        case .folderTreeRequest: return "folder_tree_request"
        case .folderTreeResult: return "folder_tree_result"
        case .createProjectRequest: return "create_project_request"
        case .createProjectResult: return "create_project_result"
        case .deleteProjectRequest: return "delete_project_request"
        case .deleteProjectResult: return "delete_project_result"
        case .runProfileMutationRequest: return "run_profile_mutation_request"
        case .runProfileResult: return "run_profile_result"
        case .runProfileRunRequest: return "run_profile_run_request"
        case .runProfileStopRequest: return "run_profile_stop_request"
        case .runnableDetectRequest: return "runnable_detect_request"
        case .runnableDetectResult: return "runnable_detect_result"
        case .runTaskUpdate: return "run_task_update"
        case .skillCatalogRequest: return "skill_catalog_request"
        case .skillCatalogResult: return "skill_catalog_result"
        case .skillMutationRequest: return "skill_mutation_request"
        case .skillMutationResult: return "skill_mutation_result"
        case .skillSourceMutationRequest: return "skill_source_mutation_request"
        case .skillSourceMutationResult: return "skill_source_mutation_result"
        case .acpRegistryRequest: return "acp_registry_request"
        case .acpRegistryResult: return "acp_registry_result"
        case .acpMutationRequest: return "acp_mutation_request"
        case .acpMutationResult: return "acp_mutation_result"
        case .mcpConfigRequest: return "mcp_config_request"
        case .mcpConfigResult: return "mcp_config_result"
        case .mcpMutationRequest: return "mcp_mutation_request"
        case .mcpMutationResult: return "mcp_mutation_result"
        case .autopilotRequest: return "autopilot_request"
        case .autopilotResult: return "autopilot_result"
        case .taskBoardRequest: return "task_board_request"
        case .taskBoardResult: return "task_board_result"
        case .taskBoardUpdate: return "task_board_update"
        case .ping: return "ping"
        case .pong: return "pong"
        case .iceCandidates: return "ice_candidates"
        case .iceSelected: return "ice_selected"
        case .unknown(let type): return type
        }
    }
}

// MARK: - Wire structs

public struct PairRequestPayload: Codable, Sendable {
    public let mobilePubkeyHex: String
    public let displayName: String
    public let platform: String
    public let appVersion: String
    public let apnsEnvironment: String?
    public init(
        mobilePubkeyHex: String,
        displayName: String,
        platform: String,
        appVersion: String,
        apnsEnvironment: String? = nil
    ) {
        self.mobilePubkeyHex = mobilePubkeyHex
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
        self.apnsEnvironment = apnsEnvironment
    }
}

public struct PairAckPayload: Codable, Sendable {
    public let accepted: Bool
    public let desktopName: String
    public let reason: String?
    public init(accepted: Bool, desktopName: String, reason: String? = nil) {
        self.accepted = accepted
        self.desktopName = desktopName
        self.reason = reason
    }
}

public struct UnpairPayload: Codable, Sendable {
    public let reason: String?
    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct APNsTokenPayload: Codable, Sendable {
    public let tokenHex: String
    public let environment: String
    public init(tokenHex: String, environment: String) {
        self.tokenHex = tokenHex
        self.environment = environment
    }
}

public struct PushTokenPayload: Codable, Sendable {
    public let provider: String
    public let token: String
    public let environment: String?

    public init(provider: String, token: String, environment: String? = nil) {
        self.provider = provider
        self.token = token
        self.environment = environment
    }
}

/// Mobile → desktop: ActivityKit push tokens for the job Live Activity. A
/// single payload reports either the device-wide push-to-start token, a
/// per-activity update token, or both. The desktop stores them per paired
/// device so it can remotely start, update, and end Live Activities over APNs.
public struct LiveActivityTokenPayload: Codable, Sendable {
    /// Device-wide push-to-start token (iOS 17.2+). Lets the desktop start a
    /// Live Activity for a new job remotely. `nil` when this payload only
    /// reports a per-activity update token.
    public let pushToStartTokenHex: String?
    /// Per-activity update token returned by `Activity.pushTokenUpdates`.
    /// `nil` when this payload only reports a push-to-start token.
    public let activityTokenHex: String?
    /// Identifier of the `Activity` the update token belongs to.
    public let activityID: String?
    /// The job (chat session) the activity tracks.
    public let sessionID: String?
    /// `true` when the user dismissed the Live Activity on the device. The
    /// desktop then forgets the activity so the next stream of the same session
    /// starts a fresh one instead of pushing to a token that no longer renders.
    public let activityDismissed: Bool?
    /// `true` when the foregrounded device started the Live Activity itself
    /// with `Activity.request`. Reported the instant the activity is created —
    /// well before its per-activity push token, which APNs can take several
    /// seconds to mint — so the desktop can cancel its deferred push-to-start
    /// and never spawn a duplicate activity.
    public let activityStartedLocally: Bool?

    public init(
        pushToStartTokenHex: String? = nil,
        activityTokenHex: String? = nil,
        activityID: String? = nil,
        sessionID: String? = nil,
        activityDismissed: Bool? = nil,
        activityStartedLocally: Bool? = nil
    ) {
        self.pushToStartTokenHex = pushToStartTokenHex
        self.activityTokenHex = activityTokenHex
        self.activityID = activityID
        self.sessionID = sessionID
        self.activityDismissed = activityDismissed
        self.activityStartedLocally = activityStartedLocally
    }
}

public struct RequestSnapshotPayload: Codable, Sendable {
    public let activeSessionID: String?
    public init(activeSessionID: String? = nil) {
        self.activeSessionID = activeSessionID
    }
}

/// Agent rate-limit usage mirrored from the desktop, so mobile can render a
/// usage section without its own Anthropic/OpenAI credentials. Each provider is
/// optional — `nil` means the desktop has no usage for it (not signed in, or an
/// ACP-only setup). Optional throughout for forward/backward wire-compatibility.
public struct MobileUsageSnapshot: Codable, Sendable, Equatable {
    /// Claude Code usage: 5-hour and 7-day limits.
    public let claudeCode: RateLimitUsage?
    /// Codex usage: 5-hour and 7-day limits.
    public let codex: RateLimitUsage?

    public init(claudeCode: RateLimitUsage? = nil, codex: RateLimitUsage? = nil) {
        self.claudeCode = claudeCode
        self.codex = codex
    }

    /// Whether at least one provider reported usage worth rendering.
    public var hasAnyUsage: Bool { claudeCode != nil || codex != nil }
}

/// A point-in-time snapshot of the paired desktop's system load — CPU, memory,
/// and thermal pressure — so mobile can render a "Computer Status" panel.
public struct HostMetricsSnapshot: Codable, Sendable, Equatable {
    /// macOS thermal pressure, mirrored from `ProcessInfo.ThermalState`.
    public enum ThermalState: String, Codable, Sendable {
        case nominal
        case fair
        case serious
        case critical
        /// A state reported by a newer desktop than this build understands.
        case unknown
    }

    /// Aggregate CPU utilization across all cores, 0–100.
    public let cpuUsagePercent: Double
    /// Resident memory in use — active + wired + compressed pages.
    public let memoryUsedBytes: UInt64
    /// Total physical memory installed on the desktop.
    public let memoryTotalBytes: UInt64
    public let thermalState: ThermalState
    /// When the desktop took the sample.
    public let sampledAt: Date

    public init(
        cpuUsagePercent: Double,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        thermalState: ThermalState,
        sampledAt: Date
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.thermalState = thermalState
        self.sampledAt = sampledAt
    }

    /// Memory utilization as a 0–100 percentage; zero when total is unknown.
    public var memoryUsedPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100
    }

    private enum CodingKeys: String, CodingKey {
        case cpuUsagePercent, memoryUsedBytes, memoryTotalBytes, thermalState, sampledAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpuUsagePercent = try c.decode(Double.self, forKey: .cpuUsagePercent)
        memoryUsedBytes = try c.decode(UInt64.self, forKey: .memoryUsedBytes)
        memoryTotalBytes = try c.decode(UInt64.self, forKey: .memoryTotalBytes)
        // Tolerate a thermal state added by a newer desktop build.
        let rawThermal = try c.decode(String.self, forKey: .thermalState)
        thermalState = ThermalState(rawValue: rawThermal) ?? .unknown
        sampledAt = try c.decode(Date.self, forKey: .sampledAt)
    }
}

public struct SnapshotPayload: Codable, Sendable {
    public let projects: [Project]
    public let sessions: [SessionSummary]
    public let branchBriefings: [MobileBranchBriefing]?
    public let briefingDocuments: [MobileBriefingDocument]?
    public let usageDashboard: UsageDashboard?
    public let threadSummaries: [MobileThreadSummary]?
    /// Current GitHub Actions CI status per desktop project. `nil` when the
    /// desktop predates CI-status sync.
    public let ciStatuses: [MobileProjectCIStatus]?
    public let settings: MobileSettingsSnapshot?
    public let activeSessionID: String?
    public let activeSessionMessages: [ChatMessage]?
    /// Whether the active thread has messages older than the window in
    /// `activeSessionMessages`. Mobile uses this to decide whether to offer
    /// "load more" as the user scrolls up. `nil`/`false` means the window is
    /// the whole thread (or the desktop predates message paging).
    public let activeSessionHasMore: Bool?
    /// Current git branch resolved per project on the desktop. Mobile uses this
    /// to surface "you're about to create a thread on branch X" when starting
    /// a new thread. Missing entries mean the project isn't a git repo or the
    /// branch couldn't be resolved.
    public let projectBranches: [ProjectBranchInfo]?
    /// Agent rate-limit usage mirrored from the desktop. `nil` when the desktop
    /// predates usage sync.
    public let usage: MobileUsageSnapshot?
    /// Desktop CPU/memory/thermal load. `nil` when the desktop predates
    /// computer-status sync.
    public let hostMetrics: HostMetricsSnapshot?
    /// Run profiles grouped per project. `nil` when the desktop predates mobile
    /// run-profile sync.
    public let runProfiles: [MobileProjectRunProfiles]?
    /// Recent and active run tasks mirrored from the desktop.
    public let runTasks: [MobileRunTaskSnapshot]?
    /// HTTP proxy exposed by the desktop so the mobile in-app browser can open
    /// localhost development servers running on the Mac.
    public let webProxy: MobileWebProxyInfo?
    /// Monotonically-increasing sequence number stamped by the desktop on every
    /// outgoing snapshot. Mobile drops snapshots whose `seq` is not strictly
    /// greater than the last one it applied, so a delayed snapshot in flight
    /// at the moment a fresher one is sent cannot reset
    /// `activeSessionMessages` to a stale page and "lose" recently-streamed
    /// text. `nil` when the desktop predates snapshot sequencing — mobile
    /// applies those as before.
    public let seq: UInt64?
    public init(
        projects: [Project],
        sessions: [SessionSummary],
        branchBriefings: [MobileBranchBriefing]? = nil,
        briefingDocuments: [MobileBriefingDocument]? = nil,
        usageDashboard: UsageDashboard? = nil,
        threadSummaries: [MobileThreadSummary]? = nil,
        ciStatuses: [MobileProjectCIStatus]? = nil,
        settings: MobileSettingsSnapshot? = nil,
        activeSessionID: String? = nil,
        activeSessionMessages: [ChatMessage]? = nil,
        activeSessionHasMore: Bool? = nil,
        projectBranches: [ProjectBranchInfo]? = nil,
        usage: MobileUsageSnapshot? = nil,
        hostMetrics: HostMetricsSnapshot? = nil,
        runProfiles: [MobileProjectRunProfiles]? = nil,
        runTasks: [MobileRunTaskSnapshot]? = nil,
        webProxy: MobileWebProxyInfo? = nil,
        seq: UInt64? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.branchBriefings = branchBriefings
        self.briefingDocuments = briefingDocuments
        self.usageDashboard = usageDashboard
        self.threadSummaries = threadSummaries
        self.ciStatuses = ciStatuses
        self.settings = settings
        self.activeSessionID = activeSessionID
        self.activeSessionMessages = activeSessionMessages
        self.activeSessionHasMore = activeSessionHasMore
        self.projectBranches = projectBranches
        self.usage = usage
        self.hostMetrics = hostMetrics
        self.runProfiles = runProfiles
        self.runTasks = runTasks
        self.webProxy = webProxy
        self.seq = seq
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, branchBriefings, briefingDocuments, usageDashboard, threadSummaries, ciStatuses, settings
        case activeSessionID, activeSessionMessages, activeSessionHasMore, projectBranches
        case usage, hostMetrics, runProfiles, runTasks, webProxy, seq
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        sessions = try c.decode([SessionSummary].self, forKey: .sessions)
        branchBriefings = try c.decodeIfPresent([MobileBranchBriefing].self, forKey: .branchBriefings)
        briefingDocuments = try c.decodeIfPresent([MobileBriefingDocument].self, forKey: .briefingDocuments)
        usageDashboard = try c.decodeIfPresent(UsageDashboard.self, forKey: .usageDashboard)
        threadSummaries = try c.decodeIfPresent([MobileThreadSummary].self, forKey: .threadSummaries)
        ciStatuses = try c.decodeIfPresent([MobileProjectCIStatus].self, forKey: .ciStatuses)
        settings = try c.decodeIfPresent(MobileSettingsSnapshot.self, forKey: .settings)
        activeSessionID = try c.decodeIfPresent(String.self, forKey: .activeSessionID)
        activeSessionMessages = try c.decodeIfPresent([ChatMessage].self, forKey: .activeSessionMessages)
        activeSessionHasMore = try c.decodeIfPresent(Bool.self, forKey: .activeSessionHasMore)
        projectBranches = try c.decodeIfPresent([ProjectBranchInfo].self, forKey: .projectBranches)
        usage = try c.decodeIfPresent(MobileUsageSnapshot.self, forKey: .usage)
        hostMetrics = try c.decodeIfPresent(HostMetricsSnapshot.self, forKey: .hostMetrics)
        runProfiles = try c.decodeIfPresent([MobileProjectRunProfiles].self, forKey: .runProfiles)
        runTasks = try c.decodeIfPresent([MobileRunTaskSnapshot].self, forKey: .runTasks)
        webProxy = try c.decodeIfPresent(MobileWebProxyInfo.self, forKey: .webProxy)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq)
    }
}

public struct MobileWebProxyInfo: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String

    public init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public struct ProjectBranchInfo: Codable, Sendable, Equatable {
    public let projectId: UUID
    public let currentBranch: String
    /// All local branches the desktop discovered via `git branch --list`.
    /// Optional for backward compatibility with older desktops that only sent
    /// the current branch.
    public let availableBranches: [String]?
    /// Whether the project's working tree has uncommitted changes (`git status`
    /// is non-empty). Drives whether the project-level "Commit All Changes"
    /// action is offered — it's hidden when this is `false`. `nil` from older
    /// desktops that predate this field, treated as "unknown" (action shown).
    public let hasUncommittedChanges: Bool?

    public init(
        projectId: UUID,
        currentBranch: String,
        availableBranches: [String]? = nil,
        hasUncommittedChanges: Bool? = nil
    ) {
        self.projectId = projectId
        self.currentBranch = currentBranch
        self.availableBranches = availableBranches
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    private enum CodingKeys: String, CodingKey {
        case projectId, currentBranch, availableBranches, hasUncommittedChanges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        currentBranch = try c.decode(String.self, forKey: .currentBranch)
        availableBranches = try c.decodeIfPresent([String].self, forKey: .availableBranches)
        hasUncommittedChanges = try c.decodeIfPresent(Bool.self, forKey: .hasUncommittedChanges)
    }
}

/// Mobile-initiated request to either switch to an existing local branch in
/// the project root, or create a new branch (and its worktree) on the desktop.
/// The desktop responds with `BranchOpResultPayload` carrying success/error,
/// then broadcasts a fresh snapshot so mobile sees the new branch state.
public struct BranchOpRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case switchExisting
        case createNew
        case initGit
    }

    public let clientRequestID: UUID
    public let projectID: UUID
    public let operation: Operation
    public let branch: String
    /// For `.createNew`: when true (or absent, for back-compat with older
    /// clients), create the branch in an isolated Git worktree. When false,
    /// create the branch and check it out in the project root instead.
    /// Ignored for other operations.
    public let useWorktree: Bool?

    public init(
        clientRequestID: UUID = UUID(),
        projectID: UUID,
        operation: Operation,
        branch: String,
        useWorktree: Bool? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.branch = branch
        self.useWorktree = useWorktree
    }
}

public struct BranchOpResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let operation: BranchOpRequestPayload.Operation
    public let branch: String
    public let ok: Bool
    public let errorMessage: String?

    public init(
        clientRequestID: UUID,
        projectID: UUID,
        operation: BranchOpRequestPayload.Operation,
        branch: String,
        ok: Bool,
        errorMessage: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.branch = branch
        self.ok = ok
        self.errorMessage = errorMessage
    }
}

// `RemoteFolderNode`, `FolderTreeRequestPayload`, `FolderTreeResultPayload`,
// `CreateProjectRequestPayload`, and `CreateProjectResultPayload` live in
// `FolderPayloads.swift` to keep this file under the line-length limit.

// `MobileProjectRunProfiles`, `MobileRunTaskSnapshot`, and the run-profile
// request/result payloads live in `RunProfilePayloads.swift`.

// `RunnableDetectRequestPayload` / `RunnableDetectResultPayload` live in
// `DetectionPayloads.swift` to keep this file under the line-length limit.
