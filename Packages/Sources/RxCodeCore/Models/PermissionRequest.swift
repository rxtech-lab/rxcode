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

public enum ToolCategory: Sendable, Equatable {
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
            let normalized = toolName.lowercased()
            if normalized.hasPrefix("mcp__") || normalized == "mcptoolcall" {
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

/// User's choice on a Claude `ExitPlanMode` tool call. Drives the plan sheet buttons on
/// `PlanSheetView` and is delivered to `AppState.respondToPlanDecision(...)` by the chat UI.
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

    /// Prefixes of result strings written by `AppState.respondToPlanDecision`.
    /// Anything starting with one of these is a user-authored decision and must
    /// be preserved across CLI tool_result events and CLI-session reloads —
    /// otherwise the plan chip would flip back to "Plan ready" once the CLI
    /// records its own follow-up text (e.g., "User has approved your plan…").
    public static let userDecisionResultPrefixes: [String] = [
        "Accepted with Ask",
        "Accepted with Edits",
        "Accepted with Auto-approve",
        "Rejected",
    ]

    /// True if `result` is a user-authored plan decision (vs. CLI-side text).
    public static func isUserDecisionResult(_ result: String) -> Bool {
        userDecisionResultPrefixes.contains { result.hasPrefix($0) }
    }

    /// Hidden follow-up user prompts that RxCode injects after a plan decision.
    /// Kept here so the chat-bubble suppressor (live + reloaded sessions) and the
    /// `AppState.continuationPrompt` producer share one source of truth — otherwise
    /// the prompt re-appears as a user bubble when the CLI jsonl is re-parsed.
    public static let continuationPromptPrefixes: [String] = [
        "Proceed with the plan.",
        "Revise the plan based on this feedback: ",
    ]

    /// True if `text` is an RxCode-injected plan-decision continuation prompt.
    /// The CLI logs these to its jsonl just like a user-authored prompt, so the
    /// reload path needs an explicit allow-list to drop them from the chat UI.
    public static func isContinuationPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return continuationPromptPrefixes.contains { trimmed.hasPrefix($0) }
    }
}

// MARK: - Pending Plan

/// Denormalized view of an `ExitPlanMode` tool call for the input-bar banner and
/// plan sheet. Sourced from `ChatBridge.pendingPlans` (computed from the current
/// session's messages). Kept in `RxCodeCore` so both the banner (RxCode target)
/// and the sheet (RxCodeChatKit) can consume it without depending on chat-view types.
public struct PendingPlan: Identifiable, Equatable, Sendable {
    /// The `ToolCall.id` of the underlying `ExitPlanMode` call. Used as the sheet's
    /// presentation id and as the key for `windowState.planDecisionHandler`.
    public let toolCallId: String
    /// Plan markdown extracted from the tool-call input or fallback `Write` block.
    public let markdown: String
    /// True while the parent assistant message is still streaming AND no plan
    /// markdown has arrived yet — banner suppresses these to avoid surfacing
    /// an empty plan to "review".
    public let isStreaming: Bool
    /// True once `respondToPlanDecision` has written a decision summary. Decided
    /// plans are excluded from the banner count but kept around so the inline
    /// status chip can render the outcome.
    public let isDecided: Bool
    /// Decision summary string ("Accepted with Edits", etc.) when decided.
    public let decisionSummary: String?

    public init(
        toolCallId: String,
        markdown: String,
        isStreaming: Bool,
        isDecided: Bool,
        decisionSummary: String?
    ) {
        self.toolCallId = toolCallId
        self.markdown = markdown
        self.isStreaming = isStreaming
        self.isDecided = isDecided
        self.decisionSummary = decisionSummary
    }

    public var id: String { toolCallId }
}
