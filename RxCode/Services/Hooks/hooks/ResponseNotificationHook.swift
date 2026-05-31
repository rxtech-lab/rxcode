import Foundation
import RxCodeCore

/// Posts the "response complete" banner when a turn finishes on its own. Fires
/// on `afterSessionEnd`, but only for a genuinely-completed, non-errored turn
/// (a cancelled turn or an errored one is suppressed). The AI summary + post are
/// done in a detached `Task` so dispatch isn't blocked on the network.
@MainActor
final class ResponseNotificationHook: Hook {
    let hookID = "builtin.responseNotification"

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        guard payload.reason == .completed, !payload.turnDidError else { return .ignored }
        guard controller.notificationsEnabled else { return .ignored }

        let responseText = payload.lastAssistantText
        let title = controller.sessionTitle(sessionId: payload.sessionId) ?? "New Session"
        let fallbackBody = controller.responseNotificationFallback(from: responseText)
        let postLocalBanner = !controller.isAppActive
        let projectId = payload.project.id
        let sessionId = payload.sessionId

        Task {
            let aiSummary = await controller.responseNotificationSummary(responseText: responseText, sessionId: sessionId)
            let body = aiSummary ?? fallbackBody
            await controller.postResponseComplete(
                title: title,
                body: body,
                projectId: projectId,
                sessionId: sessionId,
                postLocalBanner: postLocalBanner
            )
        }
        return .proceed
    }
}
