import Foundation

// MARK: - Hook Event Kind

/// Identifies a lifecycle event. Used for logging and to route a serialized
/// event to a future out-of-process plugin.
public enum HookEventKind: String, Codable, Sendable, CaseIterable {
    case onProjectNewChatStart
    case onThreadContextMenu
    case onProjectContextMenu
    case onProjectDelete
    case onSessionStart
    case beforeSessionEnd
    case afterSessionEnd
    case onRepositoryAdded
    case onRepositoryCloned
    case onQuestionAsk
    case onPermissionAsk
    case onPermissionApprove
    case onPermissionDenied
    case onPlanAccept
    case onPlanReject
    case onMCPDisconnected
    case onCIFailed
    case onRemoteConfigChanged
}

// MARK: - Why a session ended

/// Distinguishes a turn that finished on its own from one the user cancelled,
/// so a hook (e.g. the response-complete notification) can fire only on real
/// completion. `beforeSessionEnd` / `afterSessionEnd` carry this.
public enum SessionEndReason: String, Codable, Sendable {
    case completed
    case cancelled
}

// MARK: - Payloads
//
// Every payload is `Codable & Sendable` so the same value that flows to an
// in-process Swift hook can be JSON-encoded for an external plugin later.

public struct NewChatStartPayload: Codable, Sendable {
    public let projectId: UUID
    public let sessionKey: String

    public init(projectId: UUID, sessionKey: String) {
        self.projectId = projectId
        self.sessionKey = sessionKey
    }
}

public struct ThreadContextMenuPayload: Codable, Sendable {
    public let project: Project
    public let session: ChatSession.Summary

    public init(project: Project, session: ChatSession.Summary) {
        self.project = project
        self.session = session
    }
}

public struct ProjectContextMenuPayload: Codable, Sendable {
    public let project: Project

    public init(project: Project) {
        self.project = project
    }
}

public struct SessionStartPayload: Codable, Sendable {
    public let project: Project
    public let sessionKey: String

    public init(project: Project, sessionKey: String) {
        self.project = project
        self.sessionKey = sessionKey
    }
}

public struct SessionEndPayload: Codable, Sendable {
    public let project: Project
    public let sessionKey: String
    /// The resolved CLI session id (used to title the notification / look up the
    /// session summary). On the cancel path this is the in-memory session key.
    public let sessionId: String
    public let reason: SessionEndReason
    /// True when the turn itself errored — gates the auto-continue reprompt and
    /// the response-complete notification.
    public let turnDidError: Bool
    /// The most recent assistant text, captured at dispatch time for the
    /// response-complete notification body fallback.
    public let lastAssistantText: String
    /// True when the thread still had user messages queued at the moment it
    /// stopped — captured synchronously before the auto-flush pops one. Stop
    /// hooks that act on the change (code review, commit & push) defer while
    /// this is true so they only run once the queue has fully drained.
    public let hasQueuedFollowups: Bool

    public init(
        project: Project,
        sessionKey: String,
        sessionId: String,
        reason: SessionEndReason,
        turnDidError: Bool,
        lastAssistantText: String,
        hasQueuedFollowups: Bool = false
    ) {
        self.project = project
        self.sessionKey = sessionKey
        self.sessionId = sessionId
        self.reason = reason
        self.turnDidError = turnDidError
        self.lastAssistantText = lastAssistantText
        self.hasQueuedFollowups = hasQueuedFollowups
    }
}

public struct RepositoryPayload: Codable, Sendable {
    public let project: Project
    /// True when the project was added by cloning a remote repo, false for a
    /// locally-added folder.
    public let wasCloned: Bool

    public init(project: Project, wasCloned: Bool) {
        self.project = project
        self.wasCloned = wasCloned
    }
}

/// Fired when a project is removed from the IDE. Carries the full project so a
/// hook can clean up any persisted, project-scoped state (e.g. a dismissed
/// banner keyed by the project's repo) — so re-adding it starts fresh.
public struct ProjectDeletePayload: Codable, Sendable {
    public let project: Project
    public init(project: Project) {
        self.project = project
    }
}

public struct QuestionAskPayload: Codable, Sendable {
    public let toolUseId: String
    public let sessionId: String?
    public let projectId: UUID?
    public let projectName: String?

    public init(toolUseId: String, sessionId: String?, projectId: UUID?, projectName: String?) {
        self.toolUseId = toolUseId
        self.sessionId = sessionId
        self.projectId = projectId
        self.projectName = projectName
    }
}

public struct PermissionAskPayload: Codable, Sendable {
    public let toolUseId: String
    public let toolName: String
    public let sessionId: String?
    public let projectId: UUID?
    public let projectName: String?

    public init(toolUseId: String, toolName: String, sessionId: String?, projectId: UUID?, projectName: String?) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.sessionId = sessionId
        self.projectId = projectId
        self.projectName = projectName
    }
}

public struct PermissionDecisionPayload: Codable, Sendable {
    public let toolUseId: String
    public let toolName: String
    public let sessionId: String?
    public let projectId: UUID?
    /// Stable, serializable label for the decision (e.g. "allow", "deny",
    /// "allowSessionTool", "allowAndSetMode", "denyWithReason").
    public let decision: String

    public init(toolUseId: String, toolName: String, sessionId: String?, projectId: UUID?, decision: String) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.sessionId = sessionId
        self.projectId = projectId
        self.decision = decision
    }
}

public struct PlanAcceptPayload: Codable, Sendable {
    public let toolUseId: String
    public let sessionKey: String
    /// The permission mode the user accepted into: "ask" | "acceptEdits" | "auto".
    public let mode: String

    public init(toolUseId: String, sessionKey: String, mode: String) {
        self.toolUseId = toolUseId
        self.sessionKey = sessionKey
        self.mode = mode
    }
}

public struct PlanRejectPayload: Codable, Sendable {
    public let toolUseId: String
    public let sessionKey: String
    public let reason: String?

    public init(toolUseId: String, sessionKey: String, reason: String?) {
        self.toolUseId = toolUseId
        self.sessionKey = sessionKey
        self.reason = reason
    }
}

public struct MCPDisconnectedPayload: Codable, Sendable {
    public let name: String
    public let error: String?

    public init(name: String, error: String?) {
        self.name = name
        self.error = error
    }
}

public struct CIFailedPayload: Codable, Sendable {
    public let projectId: UUID?
    public let projectName: String?
    public let failingWorkflowNames: [String]

    public init(projectId: UUID?, projectName: String?, failingWorkflowNames: [String]) {
        self.projectId = projectId
        self.projectName = projectName
        self.failingWorkflowNames = failingWorkflowNames
    }
}

public struct RemoteConfigChangedPayload: Codable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}
