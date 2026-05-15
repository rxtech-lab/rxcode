import Foundation
import SwiftData

/// Persisted user decision for a single `ExitPlanMode` tool call. One row per
/// (sessionId, toolCallId). Sidecar storage so the decision survives CLI-backed
/// session reloads — the CLI's own tool_result for ExitPlanMode ("User has
/// approved your plan, you may now start coding…") would otherwise overwrite
/// the in-memory `ToolCall.result` we previously used to record the decision.
@Model
public final class PlanDecisionRecord {
    public var sessionId: String
    public var toolCallId: String
    public var summary: String
    public var updatedAt: Date

    public init(sessionId: String, toolCallId: String, summary: String, updatedAt: Date = .now) {
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.summary = summary
        self.updatedAt = updatedAt
    }
}
