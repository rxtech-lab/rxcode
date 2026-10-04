import Foundation
import RxCodeCore

extension AppState {
    /// Defaults key that routes agent turns through RxAgentSDK instead of the
    /// in-app `ClaudeService` / `CodexAppServer` / `ACPService`.
    ///
    /// A flag rather than a straight swap because the two implementations have
    /// to be comparable on the same build: the SDK owns process spawning,
    /// approval hooks and MCP rendering, so "does this behave the same?" is a
    /// question only answerable by running the same thread both ways. It goes
    /// away — along with the legacy services — once parity is established.
    ///
    /// Off unless explicitly set:
    /// `defaults write com.rxlab.RxCode UseAgentSDK -bool YES`
    static let useAgentSDKDefaultsKey = "UseAgentSDK"

    static var isAgentSDKEnabled: Bool {
        UserDefaults.standard.bool(forKey: useAgentSDKDefaultsKey)
    }

    /// Populate `agentBackendOverrides` with the SDK-backed implementations.
    ///
    /// Overrides are what `backend(for:)` consults first, so this is the whole
    /// of the switch — every call site already dispatches through that lookup.
    func installSDKBackendsIfEnabled() {
        guard Self.isAgentSDKEnabled else { return }
        let backends = SDKBackendFactory.makeBackends(
            permissionServer: permission,
            acpClients: { [weak self] in
                await MainActor.run { self?.acpClients ?? [] }
            }
        )
        for (provider, backend) in backends {
            agentBackendOverrides[provider] = backend
        }
    }
}
