import Foundation
import RxCodeCore

/// Posts a banner confirming a config change applied from a paired mobile device
/// (skill install/remove, skill source add/remove, MCP add).
@MainActor
final class RemoteConfigNotificationHook: Hook {
    let hookID = "builtin.remoteConfigNotification"

    func onRemoteConfigChanged(_ payload: RemoteConfigChangedPayload, controller: any HookController) async -> HookOutcome {
        await controller.postRemoteConfigChanged(title: payload.title, body: payload.body)
        return .proceed
    }
}
