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
    /// Extra text appended to the agent's system prompt for this turn — e.g. the
    /// accumulated briefing for the project's current branch. Claude-only.
    public let extraSystemPrompt: String?
    /// `-c` overrides handed to the Codex app-server child. Codex-only.
    public let mcpCodexOverrides: [String]
    /// JSON-RPC payload for ACP's `session/new` `mcpServers` parameter.
    /// ACP-only. Each element is an object with `name`/`command`/`args`/`env`.
    public let acpMCPServers: [JSONValue]
    /// Resolved client spec when `provider == .acp`. Ignored otherwise.
    public let acpSpec: ACPClientSpec?
    /// AppState's internal session key for the pooled ACP entry.
    public let clientSessionKey: String

    /// The turn's enabled MCP servers, unrendered.
    ///
    /// The three fields above (`mcpClaudeConfigPath`, `mcpCodexOverrides`,
    /// `acpMCPServers`) are the *same* information pre-rendered into each CLI's
    /// own config dialect, which is why there are three of them. A backend that
    /// renders its own config — every RxAgentSDK-based one does — reads this
    /// instead, and the rendered trio retires with the legacy backends.
    public let mcpServers: [MCPServerRecord]
    /// How an agent reaches the in-app IDE MCP server, when one was allocated
    /// for this turn. Provider-agnostic: it is a stdio bridge to a loopback port.
    public let ideBridgeCommand: MCPBridgeCommand?

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
        extraSystemPrompt: String? = nil,
        mcpCodexOverrides: [String] = [],
        acpMCPServers: [JSONValue] = [],
        acpSpec: ACPClientSpec? = nil,
        clientSessionKey: String,
        mcpServers: [MCPServerRecord] = [],
        ideBridgeCommand: MCPBridgeCommand? = nil
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
        self.extraSystemPrompt = extraSystemPrompt
        self.mcpCodexOverrides = mcpCodexOverrides
        self.acpMCPServers = acpMCPServers
        self.acpSpec = acpSpec
        self.clientSessionKey = clientSessionKey
        self.mcpServers = mcpServers
        self.ideBridgeCommand = ideBridgeCommand
    }
}

/// A stdio command that proxies an agent's MCP traffic to a loopback port.
public struct MCPBridgeCommand: Sendable, Hashable {
    public let command: String
    public let args: [String]

    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
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

    /// Whether this backend's transport can reach a running turn at all.
    ///
    /// `steer` answers "did this particular turn take it?", which is only
    /// knowable at the moment of the write. The UI needs the coarser answer
    /// beforehand — whether to offer the user a "steer now" action on a queued
    /// message — so it asks this instead. Synchronous and `nonisolated` because
    /// it is read from the view-state push loop on every streaming update.
    nonisolated var supportsSteering: Bool { get }

    /// Deliver extra user input to a turn that is already running, without
    /// cancelling it.
    ///
    /// Returns `false` when the backend cannot steer at all, or when this
    /// particular turn is past the point of accepting input — the agent may
    /// have finished between the user pressing send and the write landing. A
    /// caller that gets `false` still owes the user their message, so it must
    /// fall back to queueing or to interrupting and starting a new turn.
    func steer(streamId: UUID, prompt: String) async -> Bool

    /// Drain whatever the agent wrote to stderr during this stream. The UI
    /// renders it as the error bubble when a turn ends with `isError`, so a
    /// backend that has no stderr to offer should return `nil` rather than an
    /// empty string.
    func consumeStderr(for streamId: UUID) -> String?

    /// The thinking levels this agent accepts, in ascending order.
    ///
    /// Provider-specific: Claude Code's `--effort` and Codex's
    /// `model_reasoning_effort` do not take the same values, so the picker has
    /// to ask rather than assume. An empty list means the agent has no
    /// reasoning control and the picker hides itself.
    func availableReasoningLevels() async -> [ReasoningLevel]
}

public extension AgentBackend {
    func capabilities(for sessionKey: String) async -> CapabilitySet {
        staticCapabilities
    }

    func consumeStderr(for streamId: UUID) -> String? { nil }

    /// No reasoning control unless a backend says otherwise.
    func availableReasoningLevels() async -> [ReasoningLevel] { [] }

    /// Steering is opt-in: a backend whose transport has no way to reach a
    /// running turn declines, and the caller falls back.
    func steer(streamId: UUID, prompt: String) async -> Bool { false }

    nonisolated var supportsSteering: Bool { false }
}
