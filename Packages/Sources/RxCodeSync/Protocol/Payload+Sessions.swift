import Foundation
import RxCodeCore

// MARK: - Session & thread payloads

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

public struct SessionSummary: Codable, Sendable, Identifiable, Equatable {
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
    public let queuedSendMode: QueuedSendMode?
    /// Whether the session's stream finished while the user wasn't viewing it
    /// and it hasn't been opened since. Mirrors the desktop's
    /// `hasUncheckedCompletion` so mobile can show the same green
    /// "finished, unread" indicator. Defaults to `false` for summaries from
    /// an older desktop that predates this field.
    public let hasUncheckedCompletion: Bool
    public let isInterrupted: Bool
    /// Id of the thread this thread was spawned from (e.g. a `[Code Review]`
    /// thread links back to the reviewed thread). `nil` for ordinary threads.
    public let parentThreadId: String?
    /// Short label chip (e.g. `"Code Review"`). `nil` for ordinary threads.
    public let threadLabel: String?
    /// Number of distinct files this thread recorded edits to (the desktop's
    /// `ThreadStore` file-edit history). Drives whether the "Commit Files" action
    /// is offered — it's hidden when this is `0`. `nil` from older desktops that
    /// predate this field, which is treated as "unknown" (action still shown).
    public let changedFileCount: Int?

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
        hasUncheckedCompletion: Bool = false,
        isInterrupted: Bool = false,
        parentThreadId: String? = nil,
        threadLabel: String? = nil,
        changedFileCount: Int? = nil,
        queuedSendMode: QueuedSendMode? = nil
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
        self.queuedSendMode = queuedSendMode
        self.hasUncheckedCompletion = hasUncheckedCompletion
        self.isInterrupted = isInterrupted
        self.parentThreadId = parentThreadId
        self.threadLabel = threadLabel
        self.changedFileCount = changedFileCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, updatedAt, isPinned, isArchived, isStreaming, attention, progress, todos, queuedMessages, queuedSendMode, hasUncheckedCompletion, isInterrupted, parentThreadId, threadLabel, changedFileCount
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
        queuedSendMode = try container.decodeIfPresent(String.self, forKey: .queuedSendMode).flatMap(QueuedSendMode.init(rawValue:))
        hasUncheckedCompletion = try container.decodeIfPresent(Bool.self, forKey: .hasUncheckedCompletion) ?? false
        isInterrupted = try container.decodeIfPresent(Bool.self, forKey: .isInterrupted) ?? false
        parentThreadId = try container.decodeIfPresent(String.self, forKey: .parentThreadId)
        threadLabel = try container.decodeIfPresent(String.self, forKey: .threadLabel)
        changedFileCount = try container.decodeIfPresent(Int.self, forKey: .changedFileCount)
    }
}

public extension SessionSummary {
    /// Canonical chip label stamped on `[Code Review]` threads (manual or
    /// hook-spawned). Matches the desktop's `AppState.manualCodeReviewLabel`.
    static let codeReviewLabel = "Code Review"

    /// True when this summary *is* a `[Code Review]` thread. Such threads hide
    /// the "Code Review" / "Commit Files" actions since you don't review or
    /// commit a review thread itself.
    var isCodeReviewThread: Bool { threadLabel == Self.codeReviewLabel }

    /// Whether the "Commit Files" action should be offered for this thread.
    /// Hidden only when the desktop positively reported zero recorded file edits;
    /// an unknown count (`nil`, from an older desktop) keeps the action visible.
    var hasRecordedFileChanges: Bool { changedFileCount.map { $0 > 0 } ?? true }
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
    /// Persisted file edits changed, including asynchronous script detection.
    /// Optional so older desktops and mobile clients remain compatible.
    public let fileEditsChanged: Bool?

    public init(
        sessionID: String,
        kind: Kind,
        message: ChatMessage? = nil,
        isStreaming: Bool? = nil,
        isThinking: Bool? = nil,
        summary: SessionSummary? = nil,
        previousSessionID: String? = nil,
        fileEditsChanged: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.message = message
        self.isStreaming = isStreaming
        self.isThinking = isThinking
        self.summary = summary
        self.previousSessionID = previousSessionID
        self.fileEditsChanged = fileEditsChanged
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
    public let resumeInterruptedTurn: Bool?
    public init(clientMessageID: UUID = UUID(), sessionID: String, text: String, resumeInterruptedTurn: Bool? = nil) {
        self.clientMessageID = clientMessageID
        self.sessionID = sessionID
        self.text = text
        self.resumeInterruptedTurn = resumeInterruptedTurn
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
    /// Published-docs matches for the same query. Optional for wire-compatibility
    /// with desktops that predate mobile docs search — older builds omit the key
    /// and mobile decodes it as `nil` (rendered as no docs results).
    public let docHits: [DocsSearchHit]?
    public init(
        clientRequestID: UUID,
        query: String,
        projectIDs: [UUID],
        threadHits: [SearchHit],
        docHits: [DocsSearchHit]? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.query = query
        self.projectIDs = projectIDs
        self.threadHits = threadHits
        self.docHits = docHits
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

/// An IDE or computer-use confirmation awaiting the user's decision.
public struct PendingConfirmationPayload: Codable, Sendable, Identifiable, Equatable {
    /// The desktop's prompt id; echoed back in `ConfirmationDecisionPayload`.
    public let id: String
    public let sessionID: String
    public let projectID: UUID?
    public let title: String
    public let message: String?
    public let confirmLabel: String
    public let cancelLabel: String
    public let isDestructive: Bool
    public init(
        id: String,
        sessionID: String,
        projectID: UUID?,
        title: String,
        message: String?,
        confirmLabel: String,
        cancelLabel: String,
        isDestructive: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectID = projectID
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.isDestructive = isDestructive
    }
}

/// Desktop → mobile: every confirmation prompt currently awaiting
/// a decision. The desktop re-broadcasts the full set whenever a prompt is
/// queued or settled, so mobile mirrors it exactly.
public struct ConfirmationQueuePayload: Codable, Sendable {
    public let confirmations: [PendingConfirmationPayload]
    public init(confirmations: [PendingConfirmationPayload]) {
        self.confirmations = confirmations
    }
}

/// Mobile → desktop: the user confirmed or rejected prompt `id`.
public struct ConfirmationDecisionPayload: Codable, Sendable {
    public let id: String
    public let confirmed: Bool
    public init(id: String, confirmed: Bool) {
        self.id = id
        self.confirmed = confirmed
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

public struct RemoteFileRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let path: String
    public let line: Int?

    public init(clientRequestID: UUID, path: String, line: Int? = nil) {
        self.clientRequestID = clientRequestID
        self.path = path
        self.line = line
    }
}

public struct RemoteFileResultPayload: Codable, Sendable, Identifiable {
    public var id: UUID { clientRequestID }

    public let clientRequestID: UUID
    public let path: String
    public let name: String
    public let line: Int?
    public let ok: Bool
    public let errorMessage: String?
    public let content: String?
    public let truncated: Bool

    public init(
        clientRequestID: UUID,
        path: String,
        name: String,
        line: Int? = nil,
        ok: Bool,
        errorMessage: String? = nil,
        content: String? = nil,
        truncated: Bool = false
    ) {
        self.clientRequestID = clientRequestID
        self.path = path
        self.name = name
        self.line = line
        self.ok = ok
        self.errorMessage = errorMessage
        self.content = content
        self.truncated = truncated
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

public enum QueuedSendMode: String, Codable, Equatable, Sendable {
    case wait, steer, interrupt, steerOrInterrupt
}

/// Edits queued text or requests explicit delivery of a queued instruction.
/// Missing `interrupt` keeps the existing live-steering action.
public struct QueueMessageActionPayload: Codable, Sendable {
    public let sessionID: String
    public let queuedMessageID: UUID
    public let text: String?
    public let interrupt: Bool?
    public init(sessionID: String, queuedMessageID: UUID, text: String? = nil, interrupt: Bool? = nil) {
        self.sessionID = sessionID
        self.queuedMessageID = queuedMessageID
        self.text = text
        self.interrupt = interrupt
    }
}
