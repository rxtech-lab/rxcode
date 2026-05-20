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
    case searchRequest(SearchRequestPayload)
    case searchResults(SearchResultsPayload)
    case notification(NotificationPayload)
    case permissionRequest(PermissionRequestPayload)
    case permissionResponse(PermissionResponsePayload)
    case branchOpRequest(BranchOpRequestPayload)
    case branchOpResult(BranchOpResultPayload)
    case ping(PingPayload)
    case pong(PongPayload)
    case unknown(type: String)
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

public struct RequestSnapshotPayload: Codable, Sendable {
    public let activeSessionID: String?
    public init(activeSessionID: String? = nil) {
        self.activeSessionID = activeSessionID
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
    /// Current git branch resolved per project on the desktop. Mobile uses this
    /// to surface "you're about to create a thread on branch X" when starting
    /// a new thread. Missing entries mean the project isn't a git repo or the
    /// branch couldn't be resolved.
    public let projectBranches: [ProjectBranchInfo]?
    public init(
        projects: [Project],
        sessions: [SessionSummary],
        branchBriefings: [MobileBranchBriefing]? = nil,
        threadSummaries: [MobileThreadSummary]? = nil,
        settings: MobileSettingsSnapshot? = nil,
        activeSessionID: String? = nil,
        activeSessionMessages: [ChatMessage]? = nil,
        projectBranches: [ProjectBranchInfo]? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.branchBriefings = branchBriefings
        self.threadSummaries = threadSummaries
        self.settings = settings
        self.activeSessionID = activeSessionID
        self.activeSessionMessages = activeSessionMessages
        self.projectBranches = projectBranches
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, branchBriefings, threadSummaries, settings
        case activeSessionID, activeSessionMessages, projectBranches
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
        projectBranches = try c.decodeIfPresent([ProjectBranchInfo].self, forKey: .projectBranches)
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
        modelSections: [AgentModelSection]? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case selectedAgentProvider, selectedModel, selectedACPClientId, selectedEffort
        case permissionMode, summarizationProvider, summarizationProviderDisplayName
        case openAISummarizationEndpoint, openAISummarizationModel
        case notificationsEnabled, focusMode, autoArchiveEnabled, archiveRetentionDays
        case autoPreviewSettings, availableEfforts, availableModels, modelSections
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
    }
}

public struct MobileSettingsUpdatePayload: Codable, Sendable {
    public let selectedAgentProvider: AgentProvider?
    public let selectedModel: String?
    public let selectedACPClientId: String?
    public let selectedEffort: String?
    public let permissionMode: PermissionMode?
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
        self.queuedMessages = queuedMessages
        self.hasUncheckedCompletion = hasUncheckedCompletion
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, updatedAt, isPinned, isArchived, isStreaming, attention, progress, queuedMessages, hasUncheckedCompletion
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
    public init(clientRequestID: UUID = UUID(), projectID: UUID, initialText: String? = nil) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.initialText = initialText
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
        case searchRequest = "search_request"
        case searchResults = "search_results"
        case notification
        case permissionRequest = "permission_request"
        case permissionResponse = "permission_response"
        case branchOpRequest = "branch_op_request"
        case branchOpResult = "branch_op_result"
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
        case .searchRequest: self = .searchRequest(try container.decode(SearchRequestPayload.self, forKey: .data))
        case .searchResults: self = .searchResults(try container.decode(SearchResultsPayload.self, forKey: .data))
        case .notification: self = .notification(try container.decode(NotificationPayload.self, forKey: .data))
        case .permissionRequest: self = .permissionRequest(try container.decode(PermissionRequestPayload.self, forKey: .data))
        case .permissionResponse: self = .permissionResponse(try container.decode(PermissionResponsePayload.self, forKey: .data))
        case .branchOpRequest: self = .branchOpRequest(try container.decode(BranchOpRequestPayload.self, forKey: .data))
        case .branchOpResult: self = .branchOpResult(try container.decode(BranchOpResultPayload.self, forKey: .data))
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
        case .searchRequest(let p): try container.encode(TypeKey.searchRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .searchResults(let p): try container.encode(TypeKey.searchResults.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .notification(let p): try container.encode(TypeKey.notification.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionRequest(let p): try container.encode(TypeKey.permissionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionResponse(let p): try container.encode(TypeKey.permissionResponse.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .branchOpRequest(let p): try container.encode(TypeKey.branchOpRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .branchOpResult(let p): try container.encode(TypeKey.branchOpResult.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .ping(let p): try container.encode(TypeKey.ping.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pong(let p): try container.encode(TypeKey.pong.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unknown(let type): try container.encode(type, forKey: .type)
        }
    }
}
