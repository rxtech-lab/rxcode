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
    case liveActivityToken(LiveActivityTokenPayload)
    case requestSnapshot(RequestSnapshotPayload)
    case snapshot(SnapshotPayload)
    case settingsUpdate(MobileSettingsUpdatePayload)
    case sessionUpdate(SessionUpdatePayload)
    case subscribeSession(SubscribeSessionPayload)
    case userMessage(UserMessagePayload)
    case cancelStream(CancelStreamPayload)
    case removeQueuedMessage(RemoveQueuedMessagePayload)
    case newSessionRequest(NewSessionRequestPayload)
    case threadActionRequest(ThreadActionRequestPayload)
    case loadMoreMessages(LoadMoreMessagesRequestPayload)
    case moreMessages(MoreMessagesPayload)
    case threadChangesRequest(ThreadChangesRequestPayload)
    case threadChangesResult(ThreadChangesResultPayload)
    case searchRequest(SearchRequestPayload)
    case searchResults(SearchResultsPayload)
    case notification(NotificationPayload)
    case permissionRequest(PermissionRequestPayload)
    case permissionResponse(PermissionResponsePayload)
    case questionQueue(QuestionQueuePayload)
    case questionAnswer(QuestionAnswerPayload)
    case planDecision(PlanDecisionPayload)
    case branchOpRequest(BranchOpRequestPayload)
    case branchOpResult(BranchOpResultPayload)
    case folderTreeRequest(FolderTreeRequestPayload)
    case folderTreeResult(FolderTreeResultPayload)
    case createProjectRequest(CreateProjectRequestPayload)
    case createProjectResult(CreateProjectResultPayload)
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
    case ping(PingPayload)
    case pong(PongPayload)
    case unknown(type: String)
}

public extension Payload {
    var logName: String {
        switch self {
        case .pairRequest: return "pair_request"
        case .pairAck: return "pair_ack"
        case .unpair: return "unpair"
        case .apnsToken: return "apns_token"
        case .liveActivityToken: return "live_activity_token"
        case .requestSnapshot: return "request_snapshot"
        case .snapshot: return "snapshot"
        case .settingsUpdate: return "settings_update"
        case .sessionUpdate: return "session_update"
        case .subscribeSession: return "subscribe_session"
        case .userMessage: return "user_message"
        case .cancelStream: return "cancel_stream"
        case .removeQueuedMessage: return "remove_queued_message"
        case .newSessionRequest: return "new_session_request"
        case .threadActionRequest: return "thread_action_request"
        case .loadMoreMessages: return "load_more_messages"
        case .moreMessages: return "more_messages"
        case .threadChangesRequest: return "thread_changes_request"
        case .threadChangesResult: return "thread_changes_result"
        case .searchRequest: return "search_request"
        case .searchResults: return "search_results"
        case .notification: return "notification"
        case .permissionRequest: return "permission_request"
        case .permissionResponse: return "permission_response"
        case .questionQueue: return "question_queue"
        case .questionAnswer: return "question_answer"
        case .planDecision: return "plan_decision"
        case .branchOpRequest: return "branch_op_request"
        case .branchOpResult: return "branch_op_result"
        case .folderTreeRequest: return "folder_tree_request"
        case .folderTreeResult: return "folder_tree_result"
        case .createProjectRequest: return "create_project_request"
        case .createProjectResult: return "create_project_result"
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
        case .ping: return "ping"
        case .pong: return "pong"
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
    public let threadSummaries: [MobileThreadSummary]?
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
    public init(
        projects: [Project],
        sessions: [SessionSummary],
        branchBriefings: [MobileBranchBriefing]? = nil,
        threadSummaries: [MobileThreadSummary]? = nil,
        settings: MobileSettingsSnapshot? = nil,
        activeSessionID: String? = nil,
        activeSessionMessages: [ChatMessage]? = nil,
        activeSessionHasMore: Bool? = nil,
        projectBranches: [ProjectBranchInfo]? = nil,
        usage: MobileUsageSnapshot? = nil,
        hostMetrics: HostMetricsSnapshot? = nil,
        runProfiles: [MobileProjectRunProfiles]? = nil,
        runTasks: [MobileRunTaskSnapshot]? = nil,
        webProxy: MobileWebProxyInfo? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.branchBriefings = branchBriefings
        self.threadSummaries = threadSummaries
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
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, branchBriefings, threadSummaries, settings
        case activeSessionID, activeSessionMessages, activeSessionHasMore, projectBranches
        case usage, hostMetrics, runProfiles, runTasks, webProxy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        sessions = try c.decode([SessionSummary].self, forKey: .sessions)
        branchBriefings = try c.decodeIfPresent([MobileBranchBriefing].self, forKey: .branchBriefings)
        threadSummaries = try c.decodeIfPresent([MobileThreadSummary].self, forKey: .threadSummaries)
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

    public init(projectId: UUID, currentBranch: String, availableBranches: [String]? = nil) {
        self.projectId = projectId
        self.currentBranch = currentBranch
        self.availableBranches = availableBranches
    }

    private enum CodingKeys: String, CodingKey {
        case projectId, currentBranch, availableBranches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        currentBranch = try c.decode(String.self, forKey: .currentBranch)
        availableBranches = try c.decodeIfPresent([String].self, forKey: .availableBranches)
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

    public init(clientRequestID: UUID = UUID(), projectID: UUID, operation: Operation, branch: String) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.branch = branch
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

public struct MobileProjectRunProfiles: Codable, Sendable, Equatable {
    public let projectId: UUID
    public let profiles: [RunProfile]

    public init(projectId: UUID, profiles: [RunProfile]) {
        self.projectId = projectId
        self.profiles = profiles
    }
}

public struct MobileRunTaskSnapshot: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case signaled
        case stopped
    }

    public var id: UUID { taskId }

    public let taskId: UUID
    public let projectId: UUID
    public let profileId: UUID
    public let profileName: String
    public let status: Status
    public let statusLabel: String
    public let exitCode: Int32?
    public let startedAt: Date
    public let resolvedCwd: String
    public let commandPreview: String
    public let terminalOutputTail: String?

    public init(
        taskId: UUID,
        projectId: UUID,
        profileId: UUID,
        profileName: String,
        status: Status,
        statusLabel: String,
        exitCode: Int32? = nil,
        startedAt: Date,
        resolvedCwd: String,
        commandPreview: String,
        terminalOutputTail: String? = nil
    ) {
        self.taskId = taskId
        self.projectId = projectId
        self.profileId = profileId
        self.profileName = profileName
        self.status = status
        self.statusLabel = statusLabel
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.resolvedCwd = resolvedCwd
        self.commandPreview = commandPreview
        self.terminalOutputTail = terminalOutputTail
    }

    public var isRunning: Bool { status == .running }
}

public struct RunProfileMutationRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case upsert
        case delete
    }

    public let clientRequestID: UUID
    public let projectID: UUID
    public let operation: Operation
    public let profile: RunProfile?
    public let profileID: UUID?

    public init(
        clientRequestID: UUID = UUID(),
        projectID: UUID,
        operation: Operation,
        profile: RunProfile? = nil,
        profileID: UUID? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.profile = profile
        self.profileID = profileID
    }
}

public struct RunProfileRunRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let profileID: UUID

    public init(clientRequestID: UUID = UUID(), projectID: UUID, profileID: UUID) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.profileID = profileID
    }
}

public struct RunProfileStopRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let taskID: UUID?
    public let projectID: UUID?
    public let profileID: UUID?

    public init(
        clientRequestID: UUID = UUID(),
        taskID: UUID? = nil,
        projectID: UUID? = nil,
        profileID: UUID? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.taskID = taskID
        self.projectID = projectID
        self.profileID = profileID
    }
}

public struct RunProfileResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let ok: Bool
    public let errorMessage: String?
    public let profiles: [RunProfile]?
    public let task: MobileRunTaskSnapshot?

    public init(
        clientRequestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        profiles: [RunProfile]? = nil,
        task: MobileRunTaskSnapshot? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.ok = ok
        self.errorMessage = errorMessage
        self.profiles = profiles
        self.task = task
    }
}

public struct RunTaskUpdatePayload: Codable, Sendable {
    public let task: MobileRunTaskSnapshot

    public init(task: MobileRunTaskSnapshot) {
        self.task = task
    }
}

// `RunnableDetectRequestPayload` / `RunnableDetectResultPayload` live in
// `DetectionPayloads.swift` to keep this file under the line-length limit.

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
        case liveActivityToken = "live_activity_token"
        case requestSnapshot = "request_snapshot"
        case snapshot
        case settingsUpdate = "settings_update"
        case sessionUpdate = "session_update"
        case subscribeSession = "subscribe_session"
        case userMessage = "user_message"
        case cancelStream = "cancel_stream"
        case removeQueuedMessage = "remove_queued_message"
        case newSessionRequest = "new_session_request"
        case threadActionRequest = "thread_action_request"
        case loadMoreMessages = "load_more_messages"
        case moreMessages = "more_messages"
        case threadChangesRequest = "thread_changes_request"
        case threadChangesResult = "thread_changes_result"
        case searchRequest = "search_request"
        case searchResults = "search_results"
        case notification
        case permissionRequest = "permission_request"
        case permissionResponse = "permission_response"
        case questionQueue = "question_queue"
        case questionAnswer = "question_answer"
        case planDecision = "plan_decision"
        case branchOpRequest = "branch_op_request"
        case branchOpResult = "branch_op_result"
        case folderTreeRequest = "folder_tree_request"
        case folderTreeResult = "folder_tree_result"
        case createProjectRequest = "create_project_request"
        case createProjectResult = "create_project_result"
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
        case ping
        case pong
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
        case .liveActivityToken: self = .liveActivityToken(try container.decode(LiveActivityTokenPayload.self, forKey: .data))
        case .requestSnapshot: self = .requestSnapshot(try container.decode(RequestSnapshotPayload.self, forKey: .data))
        case .snapshot: self = .snapshot(try container.decode(SnapshotPayload.self, forKey: .data))
        case .settingsUpdate: self = .settingsUpdate(try container.decode(MobileSettingsUpdatePayload.self, forKey: .data))
        case .sessionUpdate: self = .sessionUpdate(try container.decode(SessionUpdatePayload.self, forKey: .data))
        case .subscribeSession: self = .subscribeSession(try container.decode(SubscribeSessionPayload.self, forKey: .data))
        case .userMessage: self = .userMessage(try container.decode(UserMessagePayload.self, forKey: .data))
        case .cancelStream: self = .cancelStream(try container.decode(CancelStreamPayload.self, forKey: .data))
        case .removeQueuedMessage: self = .removeQueuedMessage(try container.decode(RemoveQueuedMessagePayload.self, forKey: .data))
        case .newSessionRequest: self = .newSessionRequest(try container.decode(NewSessionRequestPayload.self, forKey: .data))
        case .threadActionRequest: self = .threadActionRequest(try container.decode(ThreadActionRequestPayload.self, forKey: .data))
        case .loadMoreMessages: self = .loadMoreMessages(try container.decode(LoadMoreMessagesRequestPayload.self, forKey: .data))
        case .moreMessages: self = .moreMessages(try container.decode(MoreMessagesPayload.self, forKey: .data))
        case .threadChangesRequest: self = .threadChangesRequest(try container.decode(ThreadChangesRequestPayload.self, forKey: .data))
        case .threadChangesResult: self = .threadChangesResult(try container.decode(ThreadChangesResultPayload.self, forKey: .data))
        case .searchRequest: self = .searchRequest(try container.decode(SearchRequestPayload.self, forKey: .data))
        case .searchResults: self = .searchResults(try container.decode(SearchResultsPayload.self, forKey: .data))
        case .notification: self = .notification(try container.decode(NotificationPayload.self, forKey: .data))
        case .permissionRequest: self = .permissionRequest(try container.decode(PermissionRequestPayload.self, forKey: .data))
        case .permissionResponse: self = .permissionResponse(try container.decode(PermissionResponsePayload.self, forKey: .data))
        case .questionQueue: self = .questionQueue(try container.decode(QuestionQueuePayload.self, forKey: .data))
        case .questionAnswer: self = .questionAnswer(try container.decode(QuestionAnswerPayload.self, forKey: .data))
        case .planDecision: self = .planDecision(try container.decode(PlanDecisionPayload.self, forKey: .data))
        case .branchOpRequest: self = .branchOpRequest(try container.decode(BranchOpRequestPayload.self, forKey: .data))
        case .branchOpResult: self = .branchOpResult(try container.decode(BranchOpResultPayload.self, forKey: .data))
        case .folderTreeRequest: self = .folderTreeRequest(try container.decode(FolderTreeRequestPayload.self, forKey: .data))
        case .folderTreeResult: self = .folderTreeResult(try container.decode(FolderTreeResultPayload.self, forKey: .data))
        case .createProjectRequest: self = .createProjectRequest(try container.decode(CreateProjectRequestPayload.self, forKey: .data))
        case .createProjectResult: self = .createProjectResult(try container.decode(CreateProjectResultPayload.self, forKey: .data))
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
        case .ping: self = .ping(try container.decode(PingPayload.self, forKey: .data))
        case .pong: self = .pong(try container.decode(PongPayload.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pairRequest(let p): try container.encode(TypeKey.pairRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pairAck(let p): try container.encode(TypeKey.pairAck.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unpair(let p): try container.encode(TypeKey.unpair.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .apnsToken(let p): try container.encode(TypeKey.apnsToken.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .liveActivityToken(let p): try container.encode(TypeKey.liveActivityToken.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .requestSnapshot(let p): try container.encode(TypeKey.requestSnapshot.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .snapshot(let p): try container.encode(TypeKey.snapshot.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .settingsUpdate(let p): try container.encode(TypeKey.settingsUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .sessionUpdate(let p): try container.encode(TypeKey.sessionUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .subscribeSession(let p): try container.encode(TypeKey.subscribeSession.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .userMessage(let p): try container.encode(TypeKey.userMessage.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .cancelStream(let p): try container.encode(TypeKey.cancelStream.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .removeQueuedMessage(let p): try container.encode(TypeKey.removeQueuedMessage.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .newSessionRequest(let p): try container.encode(TypeKey.newSessionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .threadActionRequest(let p): try container.encode(TypeKey.threadActionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .loadMoreMessages(let p): try container.encode(TypeKey.loadMoreMessages.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .moreMessages(let p): try container.encode(TypeKey.moreMessages.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .threadChangesRequest(let p): try container.encode(TypeKey.threadChangesRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .threadChangesResult(let p): try container.encode(TypeKey.threadChangesResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .searchRequest(let p): try container.encode(TypeKey.searchRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .searchResults(let p): try container.encode(TypeKey.searchResults.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .notification(let p): try container.encode(TypeKey.notification.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionRequest(let p): try container.encode(TypeKey.permissionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionResponse(let p): try container.encode(TypeKey.permissionResponse.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .questionQueue(let p): try container.encode(TypeKey.questionQueue.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .questionAnswer(let p): try container.encode(TypeKey.questionAnswer.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .planDecision(let p): try container.encode(TypeKey.planDecision.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .branchOpRequest(let p): try container.encode(TypeKey.branchOpRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .branchOpResult(let p): try container.encode(TypeKey.branchOpResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .folderTreeRequest(let p): try container.encode(TypeKey.folderTreeRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .folderTreeResult(let p): try container.encode(TypeKey.folderTreeResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .createProjectRequest(let p): try container.encode(TypeKey.createProjectRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .createProjectResult(let p): try container.encode(TypeKey.createProjectResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
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
        case .ping(let p): try container.encode(TypeKey.ping.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pong(let p): try container.encode(TypeKey.pong.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unknown(let type): try container.encode(type, forKey: .type)
        }
    }
}
