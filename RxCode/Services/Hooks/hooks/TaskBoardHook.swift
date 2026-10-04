import Foundation
import RxCodeCore

/// Moves a task board card through its columns' triggers as the thread it was
/// dispatched into stops and gets reviewed. Each column names where a card
/// sitting in it goes on session stop, review start, review pass and review
/// fail (`TaskColumn`). By default a stopped In Progress task enters Pending
/// Review only after a separate agent verifies completion. Incomplete or
/// unverified work returns to Pending with an attention marker.
///
/// Session stop fires on `afterSessionEnd` so it runs after the
/// response-complete notification. Errored and cancelled turns are released
/// from the locked chat column and flagged for attention.
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

        let moved = await controller.advanceTaskAfterSessionEnd(payload)
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
