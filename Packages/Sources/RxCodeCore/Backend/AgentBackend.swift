import Foundation

/// Unified send envelope passed to any `AgentBackend`. Carries the superset
/// of parameters the three current backends need; each adapter consumes only
/// the fields it cares about.
public struct BackendSendRequest: Sendable {
    public let streamId: UUID
    public let prompt: String
    public let cwd: String
    /// CLI session id (Claude) / thread id (Codex) / ACP session id, depending
    /// on the backend. `nil` means "start a new session".
    public let sessionId: String?
    public let model: String?
    public let effort: String?
    public let permissionMode: PermissionMode
    public let planMode: Bool
    /// Path to the Claude hook settings JSON written for this turn. Claude-only.
    public let hookSettingsPath: String?
    /// Path to the Claude MCP config JSON written for this turn. Claude-only.
    public let mcpClaudeConfigPath: String?
    /// `-c` overrides handed to the Codex app-server child. Codex-only.
    public let mcpCodexOverrides: [String]
    /// JSON-RPC payload for ACP's `session/new` `mcpServers` parameter.
    /// ACP-only. Each element is an object with `name`/`command`/`args`/`env`.
    public let acpMCPServers: [JSONValue]
    /// Resolved client spec when `provider == .acp`. Ignored otherwise.
    public let acpSpec: ACPClientSpec?
    /// AppState's internal session key for the pooled ACP entry.
    public let clientSessionKey: String

    public init(
        streamId: UUID,
        prompt: String,
        cwd: String,
        sessionId: String?,
        model: String?,
        effort: String? = nil,
        permissionMode: PermissionMode,
        planMode: Bool = false,
        hookSettingsPath: String? = nil,
        mcpClaudeConfigPath: String? = nil,
        mcpCodexOverrides: [String] = [],
        acpMCPServers: [JSONValue] = [],
        acpSpec: ACPClientSpec? = nil,
        clientSessionKey: String
    ) {
        self.streamId = streamId
        self.prompt = prompt
        self.cwd = cwd
        self.sessionId = sessionId
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.planMode = planMode
        self.hookSettingsPath = hookSettingsPath
        self.mcpClaudeConfigPath = mcpClaudeConfigPath
        self.mcpCodexOverrides = mcpCodexOverrides
        self.acpMCPServers = acpMCPServers
        self.acpSpec = acpSpec
        self.clientSessionKey = clientSessionKey
    }
}

/// Common surface for every agent transport (Claude CLI, Codex app-server,
/// ACP). AppState dispatches via this protocol instead of switching on
/// `AgentProvider` directly.
///
/// Lifecycle per turn:
///   1. AppState builds a `BackendSendRequest` and calls `send(_:)`.
///   2. The returned `AsyncStream<StreamEvent>` carries unified events.
///   3. On natural completion AppState calls `finalize(streamId:)`.
///   4. On user-initiated stop AppState calls `cancel(streamId:)`.
public protocol AgentBackend: Actor {
    nonisolated var provider: AgentProvider { get }
    nonisolated var staticCapabilities: CapabilitySet { get }

    /// Runtime override hook. Phase 1 returns `staticCapabilities`; Phase 2+
    /// can refine after the agent's handshake reports its real toolset.
    func capabilities(for sessionKey: String) async -> CapabilitySet

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent>
    func cancel(streamId: UUID)
    func finalize(streamId: UUID)
}

public extension AgentBackend {
    func capabilities(for sessionKey: String) async -> CapabilitySet {
        staticCapabilities
    }
}
