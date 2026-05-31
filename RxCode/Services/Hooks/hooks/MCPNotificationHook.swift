import Foundation
import RxCodeCore

/// Posts the "MCP server disconnected" banner. The connected→failed edge guard
/// (so re-probes don't spam) stays at the dispatch site.
@MainActor
final class MCPNotificationHook: Hook {
    let hookID = "builtin.mcpNotification"

    func onMCPDisconnected(_ payload: MCPDisconnectedPayload, controller: any HookController) async -> HookOutcome {
        await controller.postMCPDisconnected(name: payload.name, error: payload.error)
        return .proceed
    }
}
