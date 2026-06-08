import Foundation
import RxCodeChatKit
import RxCodeCore

// MARK: - Plan-mode session-end hook suppression

extension AppState {
    /// Whether session-end lifecycle hooks (code review, commit/push, send
    /// message, and user stop hooks) must be skipped for the current turn because
    /// it is a *planning* turn: the session is in plan mode, or the agent emitted
    /// an `ExitPlanMode` plan that the user has not decided yet. Acting on a plan
    /// (reviewing or committing it) before the user accepts it is always wrong, so
    /// this is enforced centrally in `HookManager` ahead of both the completion
    /// and cancellation dispatch paths.
    ///
    /// The CLI rotates a session's id mid-life, so the stop dispatch may key the
    /// state by either the resolved `sessionId` or the in-memory `sessionKey` —
    /// both are tried.
    func sessionEndHooksSuppressed(sessionKey: String, sessionId: String) -> Bool {
        guard let state = sessionStates[sessionId] ?? sessionStates[sessionKey] else { return false }
        if state.planMode { return true }
        return Self.hasUndecidedExitPlan(in: state)
    }

    /// True when the latest assistant run contains an `ExitPlanMode` tool call the
    /// user hasn't accepted or rejected yet (the plan is "ready" and awaiting a
    /// decision). Scans back only to the previous user turn so a plan decided in
    /// an earlier turn doesn't keep stop hooks suppressed indefinitely. A decision
    /// is recognized either from the tool result (the CLI's user-decision
    /// follow-up) or the `planDecisionSummaries` sidecar, which survives CLI
    /// session reloads that would overwrite the result.
    static func hasUndecidedExitPlan(in state: SessionStreamState) -> Bool {
        for message in state.messages.reversed() {
            if message.role == .user { break }
            for block in message.blocks {
                guard let toolCall = block.toolCall, PlanLogic.isExitPlanMode(toolCall) else { continue }
                let decidedViaResult = PlanLogic.isPlanDecided(toolCall)
                let decidedViaSidecar = state.planDecisionSummaries[toolCall.id] != nil
                if !decidedViaResult, !decidedViaSidecar { return true }
            }
        }
        return false
    }
}
