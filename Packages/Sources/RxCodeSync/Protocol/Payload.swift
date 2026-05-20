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
    case runTaskUpdate(RunTaskUpdatePayload)
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
        case .runTaskUpdate: return "run_task_update"
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
    public init(mobilePubkeyHex: String, displayName: String, platform: String, appVersion: String) {
        self.mobilePubkeyHex = mobilePubkeyHex
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
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

    public init(
        pushToStartTokenHex: String? = nil,
        activityTokenHex: String? = nil,
        activityID: String? = nil,
        sessionID: String? = nil
    ) {
        self.pushToStartTokenHex = pushToStartTokenHex
        self.activityTokenHex = activityTokenHex
        self.activityID = activityID
        self.sessionID = sessionID
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
    /// Codex usage: 5-hour and 24-hour limits.
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

public struct RemoteFolderNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }

    public let name: String
    public let path: String
    public let isSelectable: Bool
    public let children: [RemoteFolderNode]

    public init(name: String, path: String, isSelectable: Bool = true, children: [RemoteFolderNode] = []) {
        self.name = name
        self.path = path
        self.isSelectable = isSelectable
        self.children = children
    }
}

public struct FolderTreeRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    /// `nil` asks the desktop for the picker roots. Non-nil asks for that
    /// folder's immediate children.
    public let path: String?
    public let depth: Int
    public let includeHidden: Bool

    public init(
        clientRequestID: UUID = UUID(),
        path: String? = nil,
        depth: Int = 1,
        includeHidden: Bool = false
    ) {
        self.clientRequestID = clientRequestID
        self.path = path
        self.depth = depth
        self.includeHidden = includeHidden
    }
}

public struct FolderTreeResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let requestedPath: String?
    public let ok: Bool
    public let root: RemoteFolderNode?
    public let errorMessage: String?

    public init(
        clientRequestID: UUID,
        requestedPath: String?,
        ok: Bool,
        root: RemoteFolderNode? = nil,
        errorMessage: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.requestedPath = requestedPath
        self.ok = ok
        self.root = root
        self.errorMessage = errorMessage
    }
}

public struct CreateProjectRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let path: String

    public init(clientRequestID: UUID = UUID(), path: String) {
        self.clientRequestID = clientRequestID
        self.path = path
    }
}

public struct CreateProjectResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let ok: Bool
    public let project: Project?
    public let errorMessage: String?

    public init(
        clientRequestID: UUID,
        ok: Bool,
        project: Project? = nil,
        errorMessage: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.ok = ok
        self.project = project
        self.errorMessage = errorMessage
    }
}

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

public struct MobileBranchBriefing: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(projectId.uuidString)::\(branch)" }

    public let projectId: UUID
    public let branch: String
    public let briefing: String
    public let updatedAt: Date

    public init(projectId: UUID, branch: String, briefing: String, updatedAt: Date) {
        self.projectId = projectId
        self.branch = branch
        self.briefing = briefing
        self.updatedAt = updatedAt
    }
}

public struct MobileThreadSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String { sessionId }

    public let sessionId: String
    public let projectId: UUID
    public let branch: String
    public let title: String
    public let summary: String
    public let updatedAt: Date

    public init(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

/// One selectable summarization provider, mirrored from the desktop's
/// `SummarizationProvider` enum. Sent as data rather than the enum itself
/// because the enum — and its hardware-dependent availability (Apple
/// Foundation Model) — lives in the desktop target.
public struct SummarizationProviderOption: Codable, Sendable, Equatable, Identifiable {
    /// Raw value of the desktop's `SummarizationProvider` case.
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct MobileSettingsSnapshot: Codable, Sendable, Equatable {
    public let selectedAgentProvider: AgentProvider
    public let selectedModel: String
    public let selectedACPClientId: String
    public let selectedEffort: String
    public let permissionMode: PermissionMode
    public let summarizationProvider: String
    public let summarizationProviderDisplayName: String
    public let openAISummarizationEndpoint: String
    public let openAISummarizationModel: String
    public let notificationsEnabled: Bool
    public let focusMode: Bool
    public let autoArchiveEnabled: Bool
    public let archiveRetentionDays: Int
    public let autoPreviewSettings: AttachmentAutoPreviewSettings
    public let availableEfforts: [String]
    /// All agent models discovered on the desktop, flattened across providers
    /// and ACP clients. Lets mobile show a model picker without re-deriving the
    /// list itself. Optional for backward compatibility with older desktops.
    public let availableModels: [AgentModel]?
    /// Model picker sections, mirroring the desktop layout — Claude Code,
    /// Codex, and one section per enabled ACP client. Lets mobile reproduce the
    /// desktop's per-ACP-client grouping instead of collapsing every ACP client
    /// into a single bucket. Optional for backward compatibility with older
    /// desktops, which sent only the flattened `availableModels` list.
    public let modelSections: [AgentModelSection]?
    /// Summarization providers the desktop currently offers, so mobile can
    /// render a provider picker without re-deriving hardware availability.
    /// Optional for backward compatibility with older desktops.
    public let availableSummarizationProviders: [SummarizationProviderOption]?
    /// Model identifiers fetched from the OpenAI-compatible summarization
    /// endpoint, so mobile can render a model picker. Empty/`nil` when the
    /// desktop hasn't fetched them yet (e.g. no API key configured).
    public let openAISummarizationModels: [String]?

    public init(
        selectedAgentProvider: AgentProvider,
        selectedModel: String,
        selectedACPClientId: String,
        selectedEffort: String,
        permissionMode: PermissionMode,
        summarizationProvider: String,
        summarizationProviderDisplayName: String,
        openAISummarizationEndpoint: String,
        openAISummarizationModel: String,
        notificationsEnabled: Bool,
        focusMode: Bool,
        autoArchiveEnabled: Bool,
        archiveRetentionDays: Int,
        autoPreviewSettings: AttachmentAutoPreviewSettings,
        availableEfforts: [String],
        availableModels: [AgentModel]? = nil,
        modelSections: [AgentModelSection]? = nil,
        availableSummarizationProviders: [SummarizationProviderOption]? = nil,
        openAISummarizationModels: [String]? = nil
    ) {
        self.selectedAgentProvider = selectedAgentProvider
        self.selectedModel = selectedModel
        self.selectedACPClientId = selectedACPClientId
        self.selectedEffort = selectedEffort
        self.permissionMode = permissionMode
        self.summarizationProvider = summarizationProvider
        self.summarizationProviderDisplayName = summarizationProviderDisplayName
        self.openAISummarizationEndpoint = openAISummarizationEndpoint
        self.openAISummarizationModel = openAISummarizationModel
        self.notificationsEnabled = notificationsEnabled
        self.focusMode = focusMode
        self.autoArchiveEnabled = autoArchiveEnabled
        self.archiveRetentionDays = archiveRetentionDays
        self.autoPreviewSettings = autoPreviewSettings
        self.availableEfforts = availableEfforts
        self.availableModels = availableModels
        self.modelSections = modelSections
        self.availableSummarizationProviders = availableSummarizationProviders
        self.openAISummarizationModels = openAISummarizationModels
    }

    private enum CodingKeys: String, CodingKey {
        case selectedAgentProvider, selectedModel, selectedACPClientId, selectedEffort
        case permissionMode, summarizationProvider, summarizationProviderDisplayName
        case openAISummarizationEndpoint, openAISummarizationModel
        case notificationsEnabled, focusMode, autoArchiveEnabled, archiveRetentionDays
        case autoPreviewSettings, availableEfforts, availableModels, modelSections
        case availableSummarizationProviders, openAISummarizationModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedAgentProvider = try c.decode(AgentProvider.self, forKey: .selectedAgentProvider)
        selectedModel = try c.decode(String.self, forKey: .selectedModel)
        selectedACPClientId = try c.decode(String.self, forKey: .selectedACPClientId)
        selectedEffort = try c.decode(String.self, forKey: .selectedEffort)
        permissionMode = try c.decode(PermissionMode.self, forKey: .permissionMode)
        summarizationProvider = try c.decode(String.self, forKey: .summarizationProvider)
        summarizationProviderDisplayName = try c.decode(String.self, forKey: .summarizationProviderDisplayName)
        openAISummarizationEndpoint = try c.decode(String.self, forKey: .openAISummarizationEndpoint)
        openAISummarizationModel = try c.decode(String.self, forKey: .openAISummarizationModel)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        focusMode = try c.decode(Bool.self, forKey: .focusMode)
        autoArchiveEnabled = try c.decode(Bool.self, forKey: .autoArchiveEnabled)
        archiveRetentionDays = try c.decode(Int.self, forKey: .archiveRetentionDays)
        autoPreviewSettings = try c.decode(AttachmentAutoPreviewSettings.self, forKey: .autoPreviewSettings)
        availableEfforts = try c.decode([String].self, forKey: .availableEfforts)
        availableModels = try c.decodeIfPresent([AgentModel].self, forKey: .availableModels)
        modelSections = try c.decodeIfPresent([AgentModelSection].self, forKey: .modelSections)
        availableSummarizationProviders = try c.decodeIfPresent(
            [SummarizationProviderOption].self, forKey: .availableSummarizationProviders
        )
        openAISummarizationModels = try c.decodeIfPresent(
            [String].self, forKey: .openAISummarizationModels
        )
    }
}

public struct MobileSettingsUpdatePayload: Codable, Sendable {
    public let selectedAgentProvider: AgentProvider?
    public let selectedModel: String?
    public let selectedACPClientId: String?
    public let selectedEffort: String?
    public let permissionMode: PermissionMode?
    /// Raw value of a `SummarizationProvider` case the user picked on mobile.
    public let summarizationProvider: String?
    /// Model identifier picked on mobile for the OpenAI-compatible endpoint.
    public let openAISummarizationModel: String?
    public let notificationsEnabled: Bool?
    public let focusMode: Bool?
    public let autoArchiveEnabled: Bool?
    public let archiveRetentionDays: Int?
    public let autoPreviewSettings: AttachmentAutoPreviewSettings?

    public init(
        selectedAgentProvider: AgentProvider? = nil,
        selectedModel: String? = nil,
        selectedACPClientId: String? = nil,
        selectedEffort: String? = nil,
        permissionMode: PermissionMode? = nil,
        summarizationProvider: String? = nil,
        openAISummarizationModel: String? = nil,
        notificationsEnabled: Bool? = nil,
        focusMode: Bool? = nil,
        autoArchiveEnabled: Bool? = nil,
        archiveRetentionDays: Int? = nil,
        autoPreviewSettings: AttachmentAutoPreviewSettings? = nil
    ) {
        self.selectedAgentProvider = selectedAgentProvider
        self.selectedModel = selectedModel
        self.selectedACPClientId = selectedACPClientId
        self.selectedEffort = selectedEffort
        self.permissionMode = permissionMode
        self.summarizationProvider = summarizationProvider
        self.openAISummarizationModel = openAISummarizationModel
        self.notificationsEnabled = notificationsEnabled
        self.focusMode = focusMode
        self.autoArchiveEnabled = autoArchiveEnabled
        self.archiveRetentionDays = archiveRetentionDays
        self.autoPreviewSettings = autoPreviewSettings
    }
}

public struct SessionProgressSnapshot: Codable, Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let inProgress: Bool

    public init(done: Int, total: Int, inProgress: Bool) {
        self.done = done
        self.total = total
        self.inProgress = inProgress
    }
}

public enum SessionAttentionKind: String, Codable, Sendable, Equatable {
    case permission
    case question
}

public struct SessionSummary: Codable, Sendable, Identifiable {
    public let id: String
    public let projectId: UUID
    public let title: String
    public let updatedAt: Date
    public let isPinned: Bool
    public let isArchived: Bool
    public let isStreaming: Bool
    public let attention: SessionAttentionKind?
    public let progress: SessionProgressSnapshot?
    /// Latest todo items for this session. Claude sessions can still derive
    /// these from `TodoWrite` messages, but Codex plan updates are persisted as
    /// snapshots instead of message tool calls, so the mobile app needs the
    /// desktop-owned item list.
    public let todos: [TodoItem]?
    /// Messages waiting to be sent once the active turn finishes. Mirrored from
    /// the desktop's per-session queue (threadStore). `nil` when the summary
    /// comes from an older desktop that doesn't know about queue sync.
    public let queuedMessages: [QueuedUserMessage]?
    /// Whether the session's stream finished while the user wasn't viewing it
    /// and it hasn't been opened since. Mirrors the desktop's
    /// `hasUncheckedCompletion` so mobile can show the same green
    /// "finished, unread" indicator. Defaults to `false` for summaries from
    /// an older desktop that predates this field.
    public let hasUncheckedCompletion: Bool

    public init(
        id: String,
        projectId: UUID,
        title: String,
        updatedAt: Date,
        isPinned: Bool,
        isArchived: Bool,
        isStreaming: Bool = false,
        attention: SessionAttentionKind? = nil,
        progress: SessionProgressSnapshot? = nil,
        todos: [TodoItem]? = nil,
        queuedMessages: [QueuedUserMessage]? = nil,
        hasUncheckedCompletion: Bool = false
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.isStreaming = isStreaming
        self.attention = attention
        self.progress = progress
        self.todos = todos
        self.queuedMessages = queuedMessages
        self.hasUncheckedCompletion = hasUncheckedCompletion
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, updatedAt, isPinned, isArchived, isStreaming, attention, progress, todos, queuedMessages, hasUncheckedCompletion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        attention = try container.decodeIfPresent(SessionAttentionKind.self, forKey: .attention)
        progress = try container.decodeIfPresent(SessionProgressSnapshot.self, forKey: .progress)
        todos = try container.decodeIfPresent([TodoItem].self, forKey: .todos)
        queuedMessages = try container.decodeIfPresent([QueuedUserMessage].self, forKey: .queuedMessages)
        hasUncheckedCompletion = try container.decodeIfPresent(Bool.self, forKey: .hasUncheckedCompletion) ?? false
    }
}

public struct SessionUpdatePayload: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case messageAppended
        case messageUpdated
        case streamingStarted
        case streamingFinished
        case statusChanged
    }
    public let sessionID: String
    public let kind: Kind
    public let message: ChatMessage?
    public let isStreaming: Bool?
    /// Whether the agent is currently producing reasoning/thinking tokens (as
    /// opposed to output text). Drives the mobile streaming indicator's
    /// "Thinking…" label, mirroring the desktop. Optional for backward
    /// compatibility with desktops that predate thinking sync.
    public let isThinking: Bool?
    public let summary: SessionSummary?
    public let previousSessionID: String?

    public init(
        sessionID: String,
        kind: Kind,
        message: ChatMessage? = nil,
        isStreaming: Bool? = nil,
        isThinking: Bool? = nil,
        summary: SessionSummary? = nil,
        previousSessionID: String? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.message = message
        self.isStreaming = isStreaming
        self.isThinking = isThinking
        self.summary = summary
        self.previousSessionID = previousSessionID
    }
}

public struct SubscribeSessionPayload: Codable, Sendable {
    public let sessionID: String?
    public init(sessionID: String?) { self.sessionID = sessionID }
}

public struct UserMessagePayload: Codable, Sendable {
    public let clientMessageID: UUID
    public let sessionID: String
    public let text: String
    public init(clientMessageID: UUID = UUID(), sessionID: String, text: String) {
        self.clientMessageID = clientMessageID
        self.sessionID = sessionID
        self.text = text
    }
}

public struct CancelStreamPayload: Codable, Sendable {
    public let sessionID: String
    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// A user message that's waiting for the active turn to finish before being
/// sent to the agent. Mirrored to mobile via `SessionSummary.queuedMessages`.
public struct QueuedUserMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// Asks the desktop to drop the queued message from threadStore. Used by the
/// mobile UI when the user swipes a queued row away. The desktop never tries
/// to send the message after this point.
public struct RemoveQueuedMessagePayload: Codable, Sendable {
    public let sessionID: String
    public let queuedMessageID: UUID
    public init(sessionID: String, queuedMessageID: UUID) {
        self.sessionID = sessionID
        self.queuedMessageID = queuedMessageID
    }
}

public struct NewSessionRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let initialText: String?
    /// Per-thread agent configuration captured in the mobile new-thread sheet.
    /// All optional for wire-compatibility with older builds — synthesized
    /// `Codable` decodes missing keys as `nil`, in which case the desktop falls
    /// back to its global defaults.
    public let selectedAgentProvider: AgentProvider?
    public let selectedModel: String?
    public let selectedACPClientId: String?
    public let selectedEffort: String?
    public let permissionMode: PermissionMode?
    /// When `true`, the desktop starts the thread in plan mode
    /// (CLI `--permission-mode plan`).
    public let planMode: Bool?
    public init(
        clientRequestID: UUID = UUID(),
        projectID: UUID,
        initialText: String? = nil,
        selectedAgentProvider: AgentProvider? = nil,
        selectedModel: String? = nil,
        selectedACPClientId: String? = nil,
        selectedEffort: String? = nil,
        permissionMode: PermissionMode? = nil,
        planMode: Bool? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.initialText = initialText
        self.selectedAgentProvider = selectedAgentProvider
        self.selectedModel = selectedModel
        self.selectedACPClientId = selectedACPClientId
        self.selectedEffort = selectedEffort
        self.permissionMode = permissionMode
        self.planMode = planMode
    }
}

/// Mobile-initiated lifecycle action on an existing thread: rename, archive,
/// unarchive, or delete. The desktop applies the action against its
/// authoritative session store and broadcasts a fresh snapshot so every paired
/// device reconciles. Fire-and-forget — there is no dedicated result payload.
public struct ThreadActionRequestPayload: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case rename
        case archive
        case unarchive
        case delete
    }

    public let clientRequestID: UUID
    public let sessionID: String
    public let action: Action
    /// New title, required only when `action == .rename`.
    public let newTitle: String?

    public init(
        clientRequestID: UUID = UUID(),
        sessionID: String,
        action: Action,
        newTitle: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.sessionID = sessionID
        self.action = action
        self.newTitle = newTitle
    }
}

/// Mobile-initiated request for an older page of a thread's messages. Mobile
/// holds only the most recent window (see `SnapshotPayload.activeSessionMessages`)
/// and pages backwards as the user scrolls up. The desktop replies with a
/// `MoreMessagesPayload` carrying the messages strictly older than
/// `beforeMessageID`.
public struct LoadMoreMessagesRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let sessionID: String
    /// The oldest message the requester currently holds. The desktop returns
    /// messages that come before this one in the thread.
    public let beforeMessageID: UUID
    /// How many older messages to return at most.
    public let limit: Int

    public init(
        clientRequestID: UUID = UUID(),
        sessionID: String,
        beforeMessageID: UUID,
        limit: Int
    ) {
        self.clientRequestID = clientRequestID
        self.sessionID = sessionID
        self.beforeMessageID = beforeMessageID
        self.limit = limit
    }
}

/// Desktop reply to a `LoadMoreMessagesRequestPayload`: one older page of a
/// thread's messages, to be prepended to the requester's local window.
public struct MoreMessagesPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let sessionID: String
    /// Older messages in chronological order (oldest first).
    public let messages: [ChatMessage]
    /// Whether messages older than this page still remain.
    public let hasMore: Bool

    public init(
        clientRequestID: UUID,
        sessionID: String,
        messages: [ChatMessage],
        hasMore: Bool
    ) {
        self.clientRequestID = clientRequestID
        self.sessionID = sessionID
        self.messages = messages
        self.hasMore = hasMore
    }
}

/// Mobile-initiated search across all threads and projects. The desktop is
/// the authoritative source of session content, so the heavy lifting (semantic
/// matching, title/project lookups) lives there; mobile just renders results.
public struct SearchRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let query: String
    public let limit: Int
    public init(clientRequestID: UUID = UUID(), query: String, limit: Int = 25) {
        self.clientRequestID = clientRequestID
        self.query = query
        self.limit = limit
    }
}

public struct SearchHit: Codable, Sendable, Identifiable, Equatable {
    public let sessionID: String
    public let projectID: UUID
    public let title: String
    public let snippet: String
    public let updatedAt: Date
    public let score: Float
    public var id: String { sessionID }
    public init(
        sessionID: String,
        projectID: UUID,
        title: String,
        snippet: String,
        updatedAt: Date,
        score: Float
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.score = score
    }
}

public struct SearchResultsPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let query: String
    public let projectIDs: [UUID]
    public let threadHits: [SearchHit]
    public init(clientRequestID: UUID, query: String, projectIDs: [UUID], threadHits: [SearchHit]) {
        self.clientRequestID = clientRequestID
        self.query = query
        self.projectIDs = projectIDs
        self.threadHits = threadHits
    }
}

public struct NotificationPayload: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case responseComplete
        case permissionNeeded
        case questionNeeded
        case mcpDisconnected
        case generic
    }
    public let kind: Kind
    public let title: String
    public let body: String
    public let sessionID: String?
    public let projectID: UUID?
    public init(
        kind: Kind,
        title: String,
        body: String,
        sessionID: String? = nil,
        projectID: UUID? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.projectID = projectID
    }
}

public struct PermissionRequestPayload: Codable, Sendable {
    public let requestID: String
    public let toolName: String
    public let toolInputJSON: String
    public let sessionID: String?
    public init(requestID: String, toolName: String, toolInputJSON: String, sessionID: String?) {
        self.requestID = requestID
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.sessionID = sessionID
    }
}

public struct PermissionResponsePayload: Codable, Sendable {
    public let requestID: String
    public let allow: Bool
    public let denyReason: String?
    public init(requestID: String, allow: Bool, denyReason: String? = nil) {
        self.requestID = requestID
        self.allow = allow
        self.denyReason = denyReason
    }
}

/// One `AskUserQuestion` tool call awaiting the user's answer, mirrored to
/// mobile so it can render the question sheet. `toolInputJSON` is the raw,
/// JSON-encoded `input` of the tool call — it decodes to `[String: JSONValue]`,
/// the same shape `AskUserQuestion(input:)` parses on either platform.
public struct PendingQuestionPayload: Codable, Sendable, Identifiable, Equatable {
    public var id: String { toolUseID }
    public let toolUseID: String
    public let sessionID: String
    public let toolInputJSON: String
    public init(toolUseID: String, sessionID: String, toolInputJSON: String) {
        self.toolUseID = toolUseID
        self.sessionID = sessionID
        self.toolInputJSON = toolInputJSON
    }
}

/// Desktop → mobile: the complete set of `AskUserQuestion` calls currently
/// awaiting an answer across every session. The desktop is authoritative and
/// re-broadcasts the full set whenever a question is queued or resolved, so
/// mobile mirrors the desktop's question queue exactly (additions and
/// retractions alike).
public struct QuestionQueuePayload: Codable, Sendable {
    public let questions: [PendingQuestionPayload]
    public init(questions: [PendingQuestionPayload]) {
        self.questions = questions
    }
}

/// One answered question inside a `QuestionAnswerPayload`. `values` holds the
/// chosen option labels (or free-form "Other: …" text); a single-select answer
/// has exactly one value, a multi-select answer has zero or more. `multiSelect`
/// mirrors the original question so the desktop rebuilds `.single` vs `.multi`.
public struct QuestionAnswerEntry: Codable, Sendable {
    public let questionIndex: Int
    public let values: [String]
    public let multiSelect: Bool
    public init(questionIndex: Int, values: [String], multiSelect: Bool) {
        self.questionIndex = questionIndex
        self.values = values
        self.multiSelect = multiSelect
    }
}

/// Mobile → desktop: the user's answers for one `AskUserQuestion` call. An
/// empty `answers` array means the user chose "Skip All Questions" — the
/// desktop then resolves the tool call as denied instead of injecting answers.
public struct QuestionAnswerPayload: Codable, Sendable {
    public let toolUseID: String
    public let answers: [QuestionAnswerEntry]
    public init(toolUseID: String, answers: [QuestionAnswerEntry]) {
        self.toolUseID = toolUseID
        self.answers = answers
    }
}

/// Mobile → desktop: the user's decision on a Claude `ExitPlanMode` plan card.
/// Uses a flat wire shape (string action + optional reason) because
/// `PlanDecisionAction` carries an associated value (`rejectWithFeedback`).
public struct PlanDecisionPayload: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case acceptAsk
        case acceptWithEdits
        case acceptAutoApprove
        case reject
        case rejectWithFeedback
    }
    public let toolUseID: String
    public let sessionID: String
    public let action: Action
    /// Free-form revision feedback; only meaningful for `.rejectWithFeedback`.
    public let reason: String?

    public init(toolUseID: String, sessionID: String, action: Action, reason: String? = nil) {
        self.toolUseID = toolUseID
        self.sessionID = sessionID
        self.action = action
        self.reason = reason
    }

    /// Build the wire payload from the shared `PlanDecisionAction` enum.
    public init(toolUseID: String, sessionID: String, decision: PlanDecisionAction) {
        self.toolUseID = toolUseID
        self.sessionID = sessionID
        switch decision {
        case .acceptAsk:
            action = .acceptAsk
            reason = nil
        case .acceptWithEdits:
            action = .acceptWithEdits
            reason = nil
        case .acceptAutoApprove:
            action = .acceptAutoApprove
            reason = nil
        case .reject:
            action = .reject
            reason = nil
        case .rejectWithFeedback(let feedback):
            action = .rejectWithFeedback
            reason = feedback
        }
    }

    /// Map back to the shared `PlanDecisionAction` the desktop's
    /// `respondToPlanDecision` consumes. An empty reason is normalized there.
    public func toDecisionAction() -> PlanDecisionAction {
        switch action {
        case .acceptAsk: return .acceptAsk
        case .acceptWithEdits: return .acceptWithEdits
        case .acceptAutoApprove: return .acceptAutoApprove
        case .reject: return .reject
        case .rejectWithFeedback: return .rejectWithFeedback(reason: reason ?? "")
        }
    }
}

public struct PingPayload: Codable, Sendable {
    public let t: Date
    public init(t: Date = .now) { self.t = t }
}

public struct PongPayload: Codable, Sendable {
    public let t: Date
    public init(t: Date = .now) { self.t = t }
}

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
        case runTaskUpdate = "run_task_update"
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
        case .runTaskUpdate: self = .runTaskUpdate(try container.decode(RunTaskUpdatePayload.self, forKey: .data))
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
        case .runTaskUpdate(let p): try container.encode(TypeKey.runTaskUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .ping(let p): try container.encode(TypeKey.ping.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pong(let p): try container.encode(TypeKey.pong.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unknown(let type): try container.encode(type, forKey: .type)
        }
    }
}
