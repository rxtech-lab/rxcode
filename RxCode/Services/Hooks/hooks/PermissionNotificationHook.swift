import Foundation
import RxCodeCore

/// Posts the "permission needed" banner when a tool call queues for approval.
@MainActor
final class PermissionNotificationHook: Hook {
    let hookID = "builtin.permissionNotification"

    func onPermissionAsk(_ payload: PermissionAskPayload, controller: any HookController) async -> HookOutcome {
        await controller.postPermissionNeeded(
            toolName: payload.toolName,
            projectName: payload.projectName,
            projectId: payload.projectId,
            sessionId: payload.sessionId
        )
        return .proceed
    }
}
