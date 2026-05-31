import Foundation
import RxCodeCore

/// Posts the "assistant has a question" banner when an `AskUserQuestion` tool
/// call arrives.
@MainActor
final class QuestionNotificationHook: Hook {
    let hookID = "builtin.questionNotification"

    func onQuestionAsk(_ payload: QuestionAskPayload, controller: any HookController) async -> HookOutcome {
        await controller.postQuestionNeeded(
            projectName: payload.projectName,
            projectId: payload.projectId,
            sessionId: payload.sessionId
        )
        return .proceed
    }
}
