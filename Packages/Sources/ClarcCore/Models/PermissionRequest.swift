import Foundation

// MARK: - Permission Request

public struct PermissionRequest: Identifiable, Sendable {
    public let id: String
    public let toolName: String
    public let toolInput: [String: JSONValue]
    public let runToken: String
    /// Snapshotted at hook receipt so the modal isn't affected by later picker changes.
    public let streamPermissionMode: PermissionMode?
    /// CLI session this hook belongs to. Used by the UI to decide whether to auto-present
    /// (only when the user is viewing this session) versus simply queueing for later.
    public let sessionId: String?

    public init(
        id: String,
        toolName: String,
        toolInput: [String: JSONValue],
        runToken: String,
        streamPermissionMode: PermissionMode? = nil,
        sessionId: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.toolInput = toolInput
        self.runToken = runToken
        self.streamPermissionMode = streamPermissionMode
        self.sessionId = sessionId
    }
}

// MARK: - Tool Category

public enum ToolCategory: Sendable {
    case readOnly
    case fileModification
    case execution
    case mcp
    case unknown

    public init(toolName: String) {
        switch toolName.lowercased() {
        case "read", "glob", "grep", "list", "search":
            self = .readOnly
        case "edit", "write", "multiedit", "multi_edit":
            self = .fileModification
        case "bash", "execute":
            self = .execution
        default:
            if toolName.lowercased().hasPrefix("mcp__") {
                self = .mcp
            } else {
                self = .unknown
            }
        }
    }

    public var isTransient: Bool {
        self == .readOnly || self == .execution
    }

    public var sfSymbol: String {
        switch self {
        case .readOnly: return "doc.text"
        case .fileModification: return "pencil"
        case .execution: return "terminal"
        case .mcp: return "puzzlepiece.extension"
        case .unknown: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Permission Decision

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny
    /// In-memory per-tool allow for the current session (Edit/Write/MultiEdit/mcp__*).
    case allowSessionTool
    /// Per-project persistent allow for an exact Bash command string.
    case allowAlwaysCommand(command: String)
    /// Allow this tool call AND switch the session's registered permission mode to
    /// `newMode` for all subsequent hook calls. Used by the plan-card accept buttons.
    case allowAndSetMode(newMode: PermissionMode)
    /// Deny this tool call and pass `reason` back to the model via the hook's
    /// `permissionDecisionReason` so it can revise. Used by "Reject with feedback".
    case denyWithReason(reason: String)
}

// MARK: - Plan Decision

/// User's choice on a Claude `ExitPlanMode` tool call. Drives the plan card buttons on
/// `PlanCardView` and is delivered to `AppState.respondToPlanDecision(...)` by the chat UI.
public enum PlanDecisionAction: Sendable, Equatable {
    /// Allow the plan and switch the session to `.default` for the rest of the conversation.
    case acceptAsk
    /// Allow the plan and switch the session to `.acceptEdits` for the rest of the conversation.
    case acceptWithEdits
    /// Allow the plan and switch the session to `.auto` for the rest of the conversation.
    case acceptAutoApprove
    /// Deny the plan and pass `reason` to the model so it can revise.
    case rejectWithFeedback(reason: String)
    /// Deny the plan without user-authored feedback.
    case reject
}
