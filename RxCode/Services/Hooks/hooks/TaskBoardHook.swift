import Foundation
import RxCodeCore

/// Moves a task board card through its columns' triggers as the thread it was
/// dispatched into stops and gets reviewed. Each column names where a card
/// sitting in it goes on session stop, review start, review pass and review
/// fail (`TaskColumn`); by default In Progress → Pending Review on stop, and
/// Pending Review → In Progress when a review fails and a fix turn starts.
///
/// Session stop fires on `afterSessionEnd` so it runs after the
/// response-complete notification. Any finished turn counts — completed,
/// errored or cancelled. A chat column is locked against manual moves while the
/// agent owns the task, so leaving a failed run there would strand the card.
///
/// Plan mode needs no special handling here. `HookManager` already suppresses
/// every session-end hook for a planning turn (`sessionEndHooksSuppressed`), so
/// a plan-mode task does not move when the agent merely produces a plan — it
/// moves after the accepted implementation turn completes. Do not "fix" this
/// by dropping the suppression check upstream.
@MainActor
final class TaskBoardHook: Hook {
    let hookID = "builtin.taskBoard"

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        // A thread with messages still queued hasn't really finished its work —
        // wait for the queue to drain so the task moves once, at the end.
        guard !payload.hasQueuedFollowups else { return .ignored }

        let moved = controller.applyTaskTrigger(.sessionStop, sessionKey: payload.sessionKey, sessionContinues: false)
        return moved ? .proceed : .ignored
    }

    func onReviewStart(_ payload: ReviewEventPayload, controller: any HookController) async -> HookOutcome {
        let moved = controller.applyTaskTrigger(.reviewStart, sessionKey: payload.sessionKey, sessionContinues: false)
        return moved ? .proceed : .ignored
    }

    func onReviewStop(_ payload: ReviewEventPayload, controller: any HookController) async -> HookOutcome {
        // A review that was stopped or couldn't finish has no verdict to route.
        guard let passed = payload.passed else { return .ignored }
        let moved = controller.applyTaskTrigger(
            passed ? .reviewPass : .reviewFail,
            sessionKey: payload.sessionKey,
            sessionContinues: payload.fixTurnStarted
        )
        return moved ? .proceed : .ignored
    }
}
