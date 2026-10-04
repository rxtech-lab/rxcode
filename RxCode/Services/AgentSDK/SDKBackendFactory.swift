import Foundation
import RxAgentClients
import RxAgentCore
import RxCodeCore

/// Builds the RxAgentSDK-backed replacements for `ClaudeService`,
/// `CodexAppServer` and `ACPService`.
///
/// Kept apart from the backend itself because the two answer different
/// questions: `SDKAgentBackend` is about running a turn, this is about which
/// agent binary the user configured. Nothing here is wired in until
/// `AppState.installSDKBackendsIfEnabled()` decides to install it.
enum SDKBackendFactory {
    /// Every backend the SDK can supply, keyed by the provider it replaces.
    ///
    /// Capabilities stay on RxCode's own `AgentProvider.staticCapabilities`
    /// rather than being translated from the SDK's `AgentCapabilities`. The two
    /// sets overlap but answer different questions — RxCode's drives which IDE
    /// MCP polyfills get exposed, and changing that silently changes the tool
    /// surface — so translating them is a follow-up, not a freebie.
    static func makeBackends(
        permissionServer: PermissionServer,
        acpClients: @escaping @Sendable () async -> [ACPClientSpec]
    ) -> [RxCodeCore.AgentProvider: any AgentBackend] {
        [
            .claudeCode: SDKAgentBackend(
                provider: .claudeCode,
                capabilities: RxCodeCore.AgentProvider.claudeCode.staticCapabilities,
                permissionServer: permissionServer,
                resolveClient: { _ in .init(ClaudeCodeClient()) }
            ),
            .codex: SDKAgentBackend(
                provider: .codex,
                capabilities: RxCodeCore.AgentProvider.codex.staticCapabilities,
                permissionServer: permissionServer,
                resolveClient: { _ in .init(CodexClient()) }
            ),
            .acp: SDKAgentBackend(
                provider: .acp,
                capabilities: RxCodeCore.AgentProvider.acp.staticCapabilities,
                permissionServer: permissionServer,
                resolveClient: { request in
                    // The turn normally carries its resolved spec. The lookup is
                    // the fallback for one that reached the backend without it —
                    // a queued send whose spec was edited in the meantime.
                    var spec = request?.acpSpec
                    if spec == nil {
                        spec = await acpClients().first { $0.enabled }
                    }
                    guard let spec, let client = makeACPClient(spec) else { return nil }
                    return .init(client, acpClientID: spec.id)
                }
            ),
        ]
    }

    /// Translate a user-installed ACP agent into an SDK client.
    ///
    /// Returns `nil` for a spec whose launch method names nothing to run — a
    /// binary entry whose path was never filled in, say. Spawning that would
    /// fail with a worse message than "no agent configured".
    static func makeACPClient(_ spec: ACPClientSpec) -> ACPClient? {
        let id = AgentClientID.acp(spec.id)
        switch spec.launch {
        case .npx(let package, let args, let env):
            guard !package.isEmpty else { return nil }
            return ACPClient(
                npx: package,
                args: args + spec.extraArgs,
                env: env.merging(spec.extraEnv) { _, extra in extra },
                displayName: spec.displayName,
                id: id,
                modelEnvVar: spec.modelEnvVar
            )
        case .uvx(let package, let args, let env):
            guard !package.isEmpty else { return nil }
            return ACPClient(
                uvx: package,
                args: args + spec.extraArgs,
                env: env.merging(spec.extraEnv) { _, extra in extra },
                displayName: spec.displayName,
                id: id,
                modelEnvVar: spec.modelEnvVar
            )
        case .binary(let path, let args, let env):
            guard !path.isEmpty else { return nil }
            return ACPClient(
                binaryFile: URL(filePath: path),
                args: args + spec.extraArgs,
                env: env.merging(spec.extraEnv) { _, extra in extra },
                id: id,
                displayName: spec.displayName,
                modelEnvVar: spec.modelEnvVar
            )
        case .custom(let command, let args, let env):
            guard !command.isEmpty else { return nil }
            return ACPClient(
                command: command,
                args: args + spec.extraArgs,
                env: env.merging(spec.extraEnv) { _, extra in extra },
                displayName: spec.displayName,
                id: id,
                modelEnvVar: spec.modelEnvVar
            )
        }
    }
}
