import Foundation
import RxAgentCore
import RxCodeCore
import os

/// Runs RxCode turns on an RxAgentSDK client.
///
/// One instance wraps one `AgentClient` and conforms to ``AgentBackend``, so
/// `AppState` reaches it through the same `backend(for:)` lookup it uses for
/// `ClaudeService`, `CodexAppServer` and `ACPService`. Nothing above this type
/// knows which implementation answered.
///
/// The translation is narrow by design. RxCode identifies a turn by `streamId`
/// and a conversation by a session-key string; the SDK identifies them by
/// `turnID` and `AgentThreadID`. Reusing `streamId` as the turn id means
/// `cancel(streamId:)` needs no table at all, and thread ids are derived from
/// the session key so they survive a relaunch — the SDK never persists them,
/// but RxCode's resume points are keyed off the native session id anyway.
actor SDKAgentBackend: AgentBackend {
    nonisolated let provider: RxCodeCore.AgentProvider
    nonisolated let staticCapabilities: CapabilitySet

    /// What client should run a given turn.
    ///
    /// A closure rather than a stored client because ACP is not one agent but
    /// a family of them: which binary runs is a property of the turn's
    /// `acpSpec`, not of the backend. Claude and Codex resolve to the same
    /// client every time and simply ignore the request.
    struct ResolvedClient: Sendable {
        let client: any RxAgentCore.AgentClient
        /// `ACPClientSpec.id`, so discovered model lists can be attributed back
        /// to the right spec. Nil for Claude and Codex.
        let acpClientID: String?

        init(_ client: any RxAgentCore.AgentClient, acpClientID: String? = nil) {
            self.client = client
            self.acpClientID = acpClientID
        }
    }

    /// `nil` means "no turn in hand" — a discovery call that just needs to know
    /// which client this provider would use. Only the ACP resolver cares, since
    /// its client depends on the turn's `acpSpec`; it falls back to the
    /// user's first enabled agent.
    typealias ClientResolver = @Sendable (BackendSendRequest?) async -> ResolvedClient?

    private let resolveClient: ClientResolver
    private let permissionServer: PermissionServer
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "SDKAgentBackend"
    )

    /// Per-turn state. Dropped in `finalize(streamId:)`.
    private struct Turn {
        let bridge: AgentEventBridge
        /// Held so `cancel(streamId:)` can reach the same client that started
        /// the turn without resolving a second time.
        let client: any RxAgentCore.AgentClient
        var stderr: String = ""
    }
    private var turns: [UUID: Turn] = [:]

    init(
        provider: RxCodeCore.AgentProvider,
        capabilities: CapabilitySet,
        permissionServer: PermissionServer,
        resolveClient: @escaping ClientResolver
    ) {
        self.provider = provider
        self.staticCapabilities = capabilities
        self.permissionServer = permissionServer
        self.resolveClient = resolveClient
    }

    // MARK: - AgentBackend

    nonisolated func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(request, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func cancel(streamId: UUID) {
        Task { await self.cancelTurn(streamId) }
    }

    private func cancelTurn(_ streamId: UUID) async {
        guard let client = turns[streamId]?.client else { return }
        await client.cancel(turn: streamId)
    }

    /// Ask the SDK client what levels it accepts.
    ///
    /// The one piece of discovery already wired through to the SDK: Claude and
    /// Codex resolve to a fixed client, so the closure runs without a request.
    /// ACP has no standard reasoning control and reports an empty list, which
    /// the picker reads as "hide the control".
    func availableReasoningLevels() async -> [ReasoningLevel] {
        guard let resolved = await resolveClient(nil) else { return [] }
        return await resolved.client.availableReasoningLevels().map(ReasoningLevel.init)
    }

    /// Steering is not forwarded yet.
    ///
    /// `AgentClient` in the pinned SDK release has no steering entry point —
    /// it is being added on the SDK side, and `streamId` is already the SDK's
    /// `turnID`, so wiring it up is a one-line forward once that ships.
    /// Declining here means an SDK-backed turn queues the message exactly as it
    /// did before, rather than silently dropping it.
    func steer(streamId: UUID, prompt: String) async -> Bool { false }

    func finalize(streamId: UUID) {
        turns.removeValue(forKey: streamId)
    }

    func consumeStderr(for streamId: UUID) -> String? {
        guard let buffer = turns[streamId]?.stderr, !buffer.isEmpty else { return nil }
        turns[streamId]?.stderr = ""
        return buffer
    }

    // MARK: - Turn

    private func run(
        _ request: BackendSendRequest,
        into continuation: AsyncStream<StreamEvent>.Continuation
    ) async {
        guard let resolved = await resolveClient(request) else {
            // No client for this turn means a misconfigured agent, not a
            // transient failure. Report it the way a failed turn is reported so
            // the UI finalizes instead of spinning.
            logger.error("[SDK] no client for provider=\(self.provider.rawValue, privacy: .public) stream=\(request.streamId)")
            turns[request.streamId] = Turn(bridge: AgentEventBridge(), client: NoOpAgentClient())
            appendStderr("No \(provider.displayNameText) agent is configured.", for: request.streamId)
            continuation.yield(.result(ResultEvent(
                durationMs: nil, totalCostUsd: nil, sessionId: request.sessionId ?? "",
                isError: true, totalTurns: nil, usage: nil, contextWindow: nil
            )))
            continuation.finish()
            return
        }

        let bridge = AgentEventBridge(acpClientID: resolved.acpClientID)
        turns[request.streamId] = Turn(bridge: bridge, client: resolved.client)

        let sdkRequest = makeSendRequest(request)
        logger.info(
            "[SDK] turn start provider=\(self.provider.rawValue, privacy: .public) client=\(resolved.client.displayName, privacy: .public) stream=\(request.streamId) resume=\(request.sessionId ?? "<new>", privacy: .public) mcp=\(sdkRequest.mcpServers.count)"
        )

        for await event in resolved.client.send(sdkRequest) {
            // Failure detail is what the error bubble renders, and the UI reads
            // it from the backend's stderr rather than from the event — so it
            // has to be banked before the translated `.result` is yielded.
            if let detail = AgentEventBridge.failureDetail(event) {
                appendStderr(detail, for: request.streamId)
            }
            for translated in bridge.translate(event) {
                continuation.yield(translated)
            }
        }
        continuation.finish()
    }

    private func appendStderr(_ line: String, for streamId: UUID) {
        guard turns[streamId] != nil else { return }
        if !turns[streamId]!.stderr.isEmpty { turns[streamId]!.stderr += "\n" }
        turns[streamId]!.stderr += line
    }

    private func makeSendRequest(_ request: BackendSendRequest) -> AgentSendRequest {
        AgentSendRequest(
            turnID: request.streamId,
            threadID: Self.threadID(forSessionKey: request.clientSessionKey),
            resumeSessionID: request.sessionId,
            prompt: request.prompt,
            workingDirectory: URL(filePath: request.cwd),
            model: request.model,
            effort: request.effort,
            permissionMode: RxAgentCore.PermissionMode(request.permissionMode),
            planMode: request.planMode,
            contextText: request.extraSystemPrompt ?? "",
            mcpServers: request.sdkMCPServers,
            permissions: SDKPermissionResolver(
                server: permissionServer,
                sessionKey: request.clientSessionKey
            )
        )
    }

    /// Derive a stable thread id from RxCode's session key.
    ///
    /// Most session keys already *are* UUID strings, in which case the id is
    /// simply that. The rest (new-session placeholder keys, worktree-scoped
    /// keys) are folded into one so the same key always yields the same
    /// thread — the SDK uses the id only to key per-thread resources, so any
    /// stable injection will do.
    ///
    /// The fold is FNV-1a rather than `Hasher`, whose seed is randomised per
    /// process: a `Hasher`-derived id would be stable within a launch and
    /// different after the next one, which is the one property this must not
    /// have.
    static func threadID(forSessionKey key: String) -> AgentThreadID {
        if let uuid = UUID(uuidString: key) { return AgentThreadID(uuid) }
        let bytes = Array(key.utf8)
        let high = fnv1a(bytes, seed: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a(bytes, seed: 0x9e37_79b9_7f4a_7c15)
        var raw = withUnsafeBytes(of: high.bigEndian) { Array($0) }
        raw += withUnsafeBytes(of: low.bigEndian) { Array($0) }
        return AgentThreadID(UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3],
            raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11],
            raw[12], raw[13], raw[14], raw[15]
        )))
    }

    private static func fnv1a(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Stands in for the client of a turn that never found one, so the failing turn
/// still has a `Turn` entry to hang its stderr off.
private struct NoOpAgentClient: RxAgentCore.AgentClient {
    let id: AgentClientID = "unconfigured"
    let displayName = "Unconfigured"
    let provider: RxAgentCore.AgentProvider = .claudeCode
    let capabilities: AgentCapabilities = .init()

    func isAvailable() async -> Bool { false }
    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
    func cancel(turn: UUID) async {}
}
