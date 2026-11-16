import Foundation
import RxCodeCore

/// Posts the "CI failed" banner. The failure-event dedup and the
/// `notificationsEnabled` gate stay at the dispatch site.
@MainActor
final class CINotificationHook: Hook {
    let hookID = "builtin.ciNotification"

    func onCIFailed(_ payload: CIFailedPayload, controller: any HookController) async -> HookOutcome {
        await controller.postCIFailed(
            projectName: payload.projectName,
            projectId: payload.projectId,
            failingWorkflowNames: payload.failingWorkflowNames,
            runURL: payload.detailsURL
        )
        return .proceed
    }
}
