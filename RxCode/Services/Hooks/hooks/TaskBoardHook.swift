import Foundation
import RxCodeCore

/// Advances a task board card from In Progress to Pending Review when the agent
/// that was dispatched for it finishes its implementation turn.
///
/// Fires on `afterSessionEnd` so it runs after the response-complete
/// notification. Any finished turn advances the task — completed, errored or
/// cancelled. In Progress is locked against manual moves while the agent owns
/// the task, so leaving a failed run there would strand the card; Pending
/// Review is where the user looks at the outcome and decides what's next.
///
/// Plan mode needs no special handling here. `HookManager` already suppresses
/// every session-end hook for a planning turn (`sessionEndHooksSuppressed`), so
/// a plan-mode task does not advance when the agent merely produces a plan — it
/// advances after the accepted implementation turn completes. Do not "fix" this
/// by dropping the suppression check upstream.
@MainActor
final class TaskBoardHook: Hook {
    let hookID = "builtin.taskBoard"

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        // A thread with messages still queued hasn't really finished its work —
        // wait for the queue to drain so the task advances once, at the end.
        guard !payload.hasQueuedFollowups else { return .ignored }

        let advanced = controller.advanceLinkedTaskToReview(sessionKey: payload.sessionKey)
        return advanced ? .proceed : .ignored
    }
}
