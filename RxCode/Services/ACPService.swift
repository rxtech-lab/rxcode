import Foundation
import RxCodeCore
import os

// MARK: - ACPService
//
// Speaks the Agent Client Protocol (https://agentclientprotocol.com) over
// newline-delimited JSON-RPC on a child process's stdio.
//
// One ACPService instance hosts many concurrent sessions. Each session pools
// a single agent subprocess across turns of the same RxCode thread so the
// agent retains conversation memory — ACP itself doesn't pass history in
// `session/prompt`, so a fresh process per turn would treat every prompt as
// the start of a new conversation. The pool is keyed by a canonical session
// key (initially the AppState `clientSessionKey`, re-keyed to the agent's
// `session/new` sessionId once known) so subsequent turns whose key has been
// renamed in AppState still find the same process.

actor ACPService {

    private let logger = Logger(subsystem: "com.claudework", category: "ACPService")

    /// Per-pool entry. Persistent fields outlive a single turn; per-turn
    /// fields are reset before each `session/prompt`.
    private struct SessionEntry {
        // Persistent (process-level)
        let process: Process
        let stdin: FileHandle
        let spec: ACPClientSpec
        let cwd: String
        var canonicalKey: String
        var agentSessionId: String?
        var modelConfigId: String?
        var nextId: Int = 1
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var stderr: String = ""
        var stdoutReaderTask: Task<Void, Never>?

        // Per-turn (reset before `session/prompt`)
        var currentStreamId: UUID?
        var continuation: AsyncStream<StreamEvent>.Continuation?
        var liveToolCalls: Set<String> = []
        var planSyntheticId: String = "acp-plan-\(UUID().uuidString)"
        var planEmitted: Bool = false
        /// Toggled on just before `session/prompt` is sent. Some agents replay
        /// the historical conversation as `session/update` notifications during
        /// `session/load`; we discard those so they don't get rendered as live
        /// messages.
        var acceptingUpdates: Bool = false
        /// Probe entries get torn down in `probeModels` instead of pooled
        /// across turns.
        let isEphemeral: Bool
    }

    private var sessions: [String: SessionEntry] = [:]
    /// Maps an externally-issued streamId to its canonical pool key.
    private var streamToKey: [UUID: String] = [:]
    /// Maps a previously-seen pool key (e.g. AppState's "pending-…" key) to
    /// the canonical key (the agent's `session/new` sessionId). Used to
    /// resolve subsequent turns whose `clientSessionKey` was renamed by
    /// AppState's session-id reconciliation.
    private var aliasToCanonical: [String: String] = [:]

    /// Reference to the permission server for bridging `session/request_permission`.
    private weak var permissionServer: PermissionServer?

    /// Cached PATH read from the user's interactive login shell, so spawned
    /// `npx`/`uvx`/binary agents can locate `node` and friends when the host
    /// app was launched from Finder with the minimal GUI PATH.
    private var cachedShellPath: String?

    init() {}

    func setPermissionServer(_ server: PermissionServer) {
        self.permissionServer = server
    }

    // MARK: - Public Interface

    func send(
        streamId: UUID,
        prompt: String,
        cwd: String,
        sessionId: String?,
        model: String?,
        spec: ACPClientSpec,
        permissionMode: PermissionMode,
        clientSessionKey: String,
        mcpServers: [JSONValue] = []
    ) -> AsyncStream<StreamEvent> {
        logger.info("[ACP] send streamId=\(streamId.uuidString, privacy: .public) client=\(spec.displayName, privacy: .public) launch=\(spec.launch.displayKind, privacy: .public) model=\(model ?? "<default>", privacy: .public) sessionId=\(sessionId ?? "<new>", privacy: .public) mode=\(String(describing: permissionMode), privacy: .public) cwd=\(cwd, privacy: .public) clientKey=\(clientSessionKey, privacy: .public) mcpServers=\(mcpServers.count) promptLen=\(prompt.count)")
        return AsyncStream<StreamEvent> { continuation in
            let task = Task {
                await self.runTurn(
                    streamId: streamId,
                    prompt: prompt,
                    cwd: cwd,
                    incomingSessionId: sessionId,
                    model: model,
                    spec: spec,
                    permissionMode: permissionMode,
                    clientSessionKey: clientSessionKey,
                    mcpServers: mcpServers,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.handleStreamTermination(streamId: streamId) }
            }
        }
    }

    /// Releases per-stream bookkeeping for a turn that ran to completion.
    /// The pooled agent process stays alive so the next turn for the same
    /// session inherits its conversation memory.
    func finalize(streamId: UUID) {
        guard let key = streamToKey.removeValue(forKey: streamId) else { return }
        guard var entry = sessions[key] else { return }
        if entry.currentStreamId == streamId {
            entry.currentStreamId = nil
            entry.continuation = nil
            entry.acceptingUpdates = false
            entry.liveToolCalls.removeAll()
            entry.planEmitted = false
            // pending should be empty after a clean turn; if any are left,
            // resume them with streamClosed so the turn surfaces the error.
            for (_, cont) in entry.pending {
                cont.resume(throwing: ACPError.streamClosed)
            }
            entry.pending.removeAll()
        }
        sessions[key] = entry
        if entry.isEphemeral {
            killSession(key: key)
        }
        logger.info("[ACP] finalize streamId=\(streamId.uuidString, privacy: .public) key=\(key, privacy: .public) keepingProcess=\(!entry.isEphemeral) running=\(entry.process.isRunning)")
    }

    func handleStreamTermination(streamId: UUID) {
        logger.info("[ACP] stream consumer detached streamId=\(streamId.uuidString, privacy: .public)")
        finalize(streamId: streamId)
    }

    /// Cancels the in-flight turn for `streamId` via `session/cancel` but
    /// keeps the agent process alive so the user can immediately send a new
    /// prompt without losing conversation state.
    func cancel(streamId: UUID) {
        guard let key = streamToKey[streamId], let entry = sessions[key] else {
            return
        }
        if let agentSid = entry.agentSessionId {
            let frame: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": ["sessionId": agentSid]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: frame),
               let line = String(data: data, encoding: .utf8) {
                _ = try? entry.stdin.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        // Resume any pending requests with .streamClosed so the runTurn await
        // unblocks and we hit the per-turn cleanup path in finalize.
        mutateSession(key) { e in
            for (_, cont) in e.pending {
                cont.resume(throwing: ACPError.streamClosed)
            }
            e.pending.removeAll()
            e.continuation?.finish()
        }
        finalize(streamId: streamId)
    }

    func consumeStderr(for streamId: UUID) -> String? {
        guard let key = streamToKey[streamId], let entry = sessions[key] else {
            return nil
        }
        let trimmed = entry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cleanup() {
        for (key, _) in sessions {
            killSession(key: key)
        }
        sessions.removeAll()
        streamToKey.removeAll()
        aliasToCanonical.removeAll()
    }

    /// Tear down a pooled session — terminate the process and forget all
    /// references. Used by `cleanup()`, ephemeral probe sessions, and as a
    /// recovery path when a pooled process dies between turns.
    private func killSession(key: String) {
        guard var entry = sessions.removeValue(forKey: key) else { return }
        try? entry.stdin.close()
        if entry.process.isRunning {
            entry.process.terminate()
        }
        entry.stdoutReaderTask?.cancel()
        for (_, cont) in entry.pending {
            cont.resume(throwing: ACPError.streamClosed)
        }
        entry.pending.removeAll()
        entry.continuation?.finish()
        if let sid = entry.currentStreamId {
            streamToKey.removeValue(forKey: sid)
        }
        // Drop any aliases that pointed at this canonical key so future
        // lookups don't follow a dangling entry.
        let aliases = aliasToCanonical.filter { $0.value == key }.map(\.key)
        for alias in aliases { aliasToCanonical.removeValue(forKey: alias) }
    }

    /// One-shot probe that spawns the agent, runs `initialize` + `session/new`,
    /// reads the model selector (if any), then tears the process down. Used
    /// at install time to populate the model picker without requiring a real
    /// turn.
    ///
    /// Bounded by `timeout` (default 20s) so a hung agent can't wedge the
    /// UI's fetch button.
    func probeModels(
        spec: ACPClientSpec,
        cwd: String,
        timeout: Duration = .seconds(20)
    ) async throws -> ACPModelConfig? {
        let streamId = UUID()
        let key = "probe-\(streamId.uuidString)"
        logger.info("[ACP] probe start: \(spec.displayName, privacy: .public) (launch=\(spec.launch.displayKind, privacy: .public)) cwd=\(cwd, privacy: .public)")

        let (process, stdin, stdout, stderr) = try await spawn(spec: spec, model: nil, cwd: cwd)
        logger.info("[ACP] probe spawned pid=\(process.processIdentifier) for \(spec.displayName, privacy: .public)")

        var entry = SessionEntry(
            process: process,
            stdin: stdin,
            spec: spec,
            cwd: cwd,
            canonicalKey: key,
            isEphemeral: true
        )
        entry.currentStreamId = streamId
        sessions[key] = entry
        streamToKey[streamId] = key

        startStderrReader(key: key, stderr: stderr)
        let readerTask = Self.spawnStdoutReader(key: key, stdout: stdout, service: self)
        mutateSession(key) { $0.stdoutReaderTask = readerTask }
        process.terminationHandler = { [weak self] _ in
            Task.detached { await self?.handleProcessExit(key: key) }
        }

        do {
            let result = try await withThrowingTaskGroup(of: ACPModelConfig?.self) { group in
                group.addTask {
                    try await self.runProbeSequence(key: key, spec: spec, cwd: cwd)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ACPError.probeTimeout(seconds: Int(timeout.components.seconds))
                }
                let value = try await group.next() ?? nil
                group.cancelAll()
                return value
            }
            readerTask.cancel()
            killSession(key: key)
            streamToKey.removeValue(forKey: streamId)
            return result
        } catch {
            let stderrSnapshot = sessions[key]?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderrSnapshot.isEmpty {
                logger.error("[ACP] probe stderr for \(spec.displayName, privacy: .public): \(stderrSnapshot, privacy: .public)")
            }
            readerTask.cancel()
            killSession(key: key)
            streamToKey.removeValue(forKey: streamId)
            throw error
        }
    }

    private func runProbeSequence(
        key: String,
        spec: ACPClientSpec,
        cwd: String
    ) async throws -> ACPModelConfig? {
        logger.info("[ACP] probe → initialize \(spec.displayName, privacy: .public)")
        _ = try await sendRequest(
            key: key,
            method: "initialize",
            params: [
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(true),
                        "writeTextFile": .bool(true)
                    ])
                ])
            ]
        )
        logger.info("[ACP] probe ← initialize ok \(spec.displayName, privacy: .public)")

        logger.info("[ACP] probe → session/new \(spec.displayName, privacy: .public)")
        let newResult = try await sendRequest(
            key: key,
            method: "session/new",
            params: [
                "cwd": .string(cwd),
                "mcpServers": .array([])
            ]
        )
        let optionCount = newResult.objectValue?["configOptions"]?.arrayValue?.count ?? 0
        logger.info("[ACP] probe ← session/new ok \(spec.displayName, privacy: .public) configOptions=\(optionCount)")

        let config = Self.parseModelConfig(from: newResult)
        if let config {
            logger.info("[ACP] probe parsed model selector configId=\(config.configId, privacy: .public) current=\(config.currentValue ?? "nil", privacy: .public) models=\(config.options.count) [\(Self.modelListDescription(config.options), privacy: .public)]")
        } else {
            logger.info("[ACP] probe found no model selector for \(spec.displayName, privacy: .public)")
        }
        return config
    }

    // MARK: - Turn Runner

    private func runTurn(
        streamId: UUID,
        prompt: String,
        cwd: String,
        incomingSessionId: String?,
        model: String?,
        spec: ACPClientSpec,
        permissionMode: PermissionMode,
        clientSessionKey: String,
        mcpServers: [JSONValue] = [],
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async {
        do {
            // Resolve the pool key — AppState may pass the original
            // `pending-…` key OR the agent's later sessionId. Either should
            // map to the same pooled entry.
            let resolvedKey = aliasToCanonical[clientSessionKey] ?? clientSessionKey
            let canReuse: Bool = {
                guard let existing = sessions[resolvedKey] else { return false }
                guard !existing.isEphemeral else { return false }
                guard existing.spec.id == spec.id else { return false }
                guard existing.cwd == cwd else { return false }
                guard existing.process.isRunning else { return false }
                guard existing.agentSessionId != nil else { return false }
                return true
            }()

            if canReuse {
                try await runReusedTurn(
                    streamId: streamId,
                    poolKey: resolvedKey,
                    prompt: prompt,
                    model: model,
                    continuation: continuation
                )
                return
            }

            // Pool has a stale entry (different spec/cwd or process dead).
            if sessions[resolvedKey] != nil {
                logger.info("[ACP] dropping stale pooled session for key=\(resolvedKey, privacy: .public)")
                killSession(key: resolvedKey)
            }

            try await runFreshTurn(
                streamId: streamId,
                bootstrapKey: clientSessionKey,
                prompt: prompt,
                cwd: cwd,
                incomingSessionId: incomingSessionId,
                model: model,
                spec: spec,
                permissionMode: permissionMode,
                mcpServers: mcpServers,
                continuation: continuation
            )
        } catch {
            logger.error("[ACP] turn failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.user(UserMessage(
                toolUseId: nil,
                content: "ACP error: \(error.localizedDescription)",
                isError: true
            )))
            continuation.finish()
            finalize(streamId: streamId)
        }
    }

    private func runFreshTurn(
        streamId: UUID,
        bootstrapKey: String,
        prompt: String,
        cwd: String,
        incomingSessionId: String?,
        model: String?,
        spec: ACPClientSpec,
        permissionMode: PermissionMode,
        mcpServers: [JSONValue] = [],
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async throws {
        let (process, stdin, stdout, stderr) = try await spawn(spec: spec, model: model, cwd: cwd)
        var entry = SessionEntry(
            process: process,
            stdin: stdin,
            spec: spec,
            cwd: cwd,
            canonicalKey: bootstrapKey,
            isEphemeral: false
        )
        entry.continuation = continuation
        entry.currentStreamId = streamId
        sessions[bootstrapKey] = entry
        streamToKey[streamId] = bootstrapKey

        // Reader closures capture the canonical key, not the streamId, so
        // the readers keep delivering correctly across turns when the pool
        // entry is later re-keyed to the agent's sessionId.
        startStderrReader(key: bootstrapKey, stderr: stderr)
        let readerTask = Self.spawnStdoutReader(key: bootstrapKey, stdout: stdout, service: self)
        mutateSession(bootstrapKey) { $0.stdoutReaderTask = readerTask }
        process.terminationHandler = { [weak self] _ in
            // Use the canonical key at exit time — `handleProcessExit` looks
            // up via the alias map, so this works even if the pool entry has
            // since been re-keyed to the agent's sessionId.
            Task.detached { await self?.handleProcessExit(key: bootstrapKey) }
        }

        let heartbeat = Task.detached { [weak self, displayName = spec.displayName, launchKind = spec.launch.displayKind] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                let elapsed = Int(Date().timeIntervalSince(started))
                await self?.heartbeatTick(displayName: displayName, elapsed: elapsed, launchKind: launchKind)
            }
        }

        // 1. initialize
        let initResult = try await sendRequest(
            key: bootstrapKey,
            method: "initialize",
            params: [
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(true),
                        "writeTextFile": .bool(true)
                    ])
                ])
            ]
        )
        heartbeat.cancel()
        logger.info("[ACP] initialize ok for \(spec.displayName, privacy: .public): \(initResult.shortDescription, privacy: .public)")
        logger.info("[ACP-MCP] runFreshTurn received \(mcpServers.count, privacy: .public) candidate mcpServers from caller")
        let filteredMCPServers = supportedMCPServers(mcpServers, initResult: initResult)
        if let data = try? JSONEncoder().encode(JSONValue.array(filteredMCPServers)),
           let json = String(data: data, encoding: .utf8) {
            logger.info("[ACP-MCP] session/new mcpServers payload=\(json, privacy: .public)")
        }

        continuation.yield(.system(SystemEvent(
            subtype: "init",
            sessionId: incomingSessionId,
            tools: nil,
            model: model,
            claudeCodeVersion: nil
        )))

        // 2. session/new — fresh ACP session backed by the new process. The
        // agent's history will accumulate within this process across pooled
        // turns; we don't use `session/load` because that re-emits the
        // persisted conversation as updates and would duplicate messages.
        let newParams: [String: JSONValue] = [
            "cwd": .string(cwd),
            "mcpServers": .array(filteredMCPServers)
        ]
        let newResult = try await sendRequest(key: bootstrapKey, method: "session/new", params: newParams)
        guard let agentSessionId = newResult.objectValue?["sessionId"]?.stringValue else {
            throw ACPError.protocolMismatch("session/new returned no sessionId")
        }
        let modelConfig = Self.parseModelConfig(from: newResult)
        _ = incomingSessionId

        // Re-key the pool entry to the agent's sessionId so subsequent turns
        // (where AppState's sessionKey is the agent sid) hit the cache.
        let canonicalKey = agentSessionId
        if canonicalKey != bootstrapKey {
            if var moved = sessions.removeValue(forKey: bootstrapKey) {
                moved.canonicalKey = canonicalKey
                moved.agentSessionId = agentSessionId
                moved.modelConfigId = modelConfig?.configId
                sessions[canonicalKey] = moved
            }
            streamToKey[streamId] = canonicalKey
            aliasToCanonical[bootstrapKey] = canonicalKey
        } else {
            mutateSession(canonicalKey) {
                $0.agentSessionId = agentSessionId
                $0.modelConfigId = modelConfig?.configId
            }
        }

        if let modelConfig {
            logger.info("[ACP] discovered model selector for \(spec.displayName, privacy: .public) configId=\(modelConfig.configId, privacy: .public) current=\(modelConfig.currentValue ?? "nil", privacy: .public) models=\(modelConfig.options.count) [\(Self.modelListDescription(modelConfig.options), privacy: .public)]")
            continuation.yield(.acpModelsDiscovered(ACPModelsDiscoveredEvent(
                clientId: spec.id,
                config: modelConfig
            )))
        } else {
            logger.info("[ACP] no model selector discovered for \(spec.displayName, privacy: .public)")
        }

        try await applyModelSelection(
            key: canonicalKey,
            agentSessionId: agentSessionId,
            modelConfig: modelConfig,
            model: model
        )

        continuation.yield(.system(SystemEvent(
            subtype: "session_started",
            sessionId: agentSessionId,
            tools: nil,
            model: model,
            claudeCodeVersion: nil
        )))

        try await runPrompt(
            key: canonicalKey,
            agentSessionId: agentSessionId,
            prompt: prompt,
            continuation: continuation
        )
    }

    private func runReusedTurn(
        streamId: UUID,
        poolKey: String,
        prompt: String,
        model: String?,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async throws {
        guard let agentSessionId = sessions[poolKey]?.agentSessionId else {
            throw ACPError.protocolMismatch("pooled session missing agentSessionId")
        }
        let modelConfigId = sessions[poolKey]?.modelConfigId
        let spec = sessions[poolKey]!.spec
        logger.info("[ACP] reusing pooled session key=\(poolKey, privacy: .public) agentSid=\(agentSessionId, privacy: .public) client=\(spec.displayName, privacy: .public)")
        logger.info("[ACP-MCP] reused turn — NOT re-sending mcpServers; agent already has whatever was registered at initial session/new")

        // Reset per-turn state and adopt the new streamId/continuation.
        mutateSession(poolKey) { e in
            e.currentStreamId = streamId
            e.continuation = continuation
            e.liveToolCalls.removeAll()
            e.planEmitted = false
            e.planSyntheticId = "acp-plan-\(UUID().uuidString)"
            e.acceptingUpdates = false
        }
        streamToKey[streamId] = poolKey

        continuation.yield(.system(SystemEvent(
            subtype: "init",
            sessionId: agentSessionId,
            tools: nil,
            model: model,
            claudeCodeVersion: nil
        )))

        // Apply model change if the user picked a different one for this turn.
        if let modelConfigId, let model, !model.isEmpty {
            let cfg = ACPModelConfig(configId: modelConfigId, currentValue: nil, options: [
                ACPModelOption(value: model, name: model, description: nil)
            ])
            try await applyModelSelection(
                key: poolKey,
                agentSessionId: agentSessionId,
                modelConfig: cfg,
                model: model
            )
        }

        continuation.yield(.system(SystemEvent(
            subtype: "session_started",
            sessionId: agentSessionId,
            tools: nil,
            model: model,
            claudeCodeVersion: nil
        )))

        try await runPrompt(
            key: poolKey,
            agentSessionId: agentSessionId,
            prompt: prompt,
            continuation: continuation
        )
    }

    /// Issues `session/set_config_option` to switch the agent's active model
    /// when the user picked a different value than the one currently selected.
    /// Best-effort: failures are logged but don't abort the turn.
    private func applyModelSelection(
        key: String,
        agentSessionId: String,
        modelConfig: ACPModelConfig?,
        model: String?
    ) async throws {
        guard let modelConfig,
              let model,
              !model.isEmpty,
              modelConfig.options.contains(where: { $0.value == model }),
              modelConfig.currentValue != model
        else { return }
        do {
            _ = try await sendRequest(
                key: key,
                method: "session/set_config_option",
                params: [
                    "sessionId": .string(agentSessionId),
                    "configId": .string(modelConfig.configId),
                    "value": .string(model)
                ]
            )
        } catch {
            logger.warning("[ACP] session/set_config_option failed for model \(model, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runPrompt(
        key: String,
        agentSessionId: String,
        prompt: String,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async throws {
        // Flip the gate AFTER any optional `session/set_config_option`
        // exchange so we don't accept stray updates before the prompt is
        // actually in flight.
        mutateSession(key) { $0.acceptingUpdates = true }
        let promptResult = try await sendRequest(
            key: key,
            method: "session/prompt",
            params: [
                "sessionId": .string(agentSessionId),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(prompt)
                ])])
            ]
        )

        let stopReason = promptResult.objectValue?["stopReason"]?.stringValue ?? "end_turn"
        continuation.yield(.result(ResultEvent(
            durationMs: nil,
            totalCostUsd: nil,
            sessionId: agentSessionId,
            isError: stopReason == "refusal",
            totalTurns: nil,
            usage: nil,
            contextWindow: nil
        )))

        continuation.finish()
        if let streamId = sessions[key]?.currentStreamId {
            finalize(streamId: streamId)
        }
    }

    private func heartbeatTick(displayName: String, elapsed: Int, launchKind: String) {
        let hint = launchKind == "npx"
            ? " (npx cold-start is ~10s; first run may install the package)"
            : ""
        logger.notice("[ACP] still waiting for \(displayName, privacy: .public) response after \(elapsed)s\(hint, privacy: .public)")
    }

    // MARK: - Process Spawn

    private func spawn(spec: ACPClientSpec, model: String?, cwd: String) async
        throws -> (Process, FileHandle, FileHandle, FileHandle)
    {
        let (executable, args, baseEnv) = try resolveLaunch(spec.launch)
        let allArgs = args + spec.extraArgs
        logger.info("[ACP] spawn exec=\(executable, privacy: .public) args=[\(allArgs.joined(separator: " "), privacy: .public)] cwd=\(cwd, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = allArgs
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = await resolvedEnvironment()
        env.merge(baseEnv) { _, new in new }
        env.merge(spec.extraEnv) { _, new in new }
        if let envVar = spec.modelEnvVar, let model, !model.isEmpty {
            env[envVar] = model
            logger.info("[ACP] spawn injecting model env \(envVar, privacy: .public)=\(model, privacy: .public)")
        }
        process.environment = env
        logger.info("[ACP] spawn PATH=\(env["PATH"] ?? "<unset>", privacy: .public)")

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            logger.info("[ACP] spawn ok pid=\(process.processIdentifier) for \(spec.displayName, privacy: .public)")
        } catch {
            logger.error("[ACP] spawn FAILED exec=\(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return (process, stdinPipe.fileHandleForWriting,
                stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading)
    }

    private func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let cachedShellPath {
            env["PATH"] = cachedShellPath
            return env
        }
        let shellPath = await readUserShellPath()
        if let shellPath, !shellPath.isEmpty {
            cachedShellPath = shellPath
            env["PATH"] = shellPath
            logger.info("[ACP] resolved login shell PATH (\(shellPath.split(separator: ":").count) entries)")
        } else {
            logger.warning("[ACP] could not read login shell PATH; using GUI PATH=\(env["PATH"] ?? "<unset>", privacy: .public)")
        }
        return env
    }

    private func readUserShellPath() async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", "print -rn -- $PATH"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (out?.isEmpty ?? true) ? nil : out
            } catch {
                return nil
            }
        }.value
    }

    private func resolveLaunch(_ launch: ACPClientSpec.LaunchKind)
        throws -> (String, [String], [String: String])
    {
        switch launch {
        case .npx(let package, let args, let env):
            return ("/usr/bin/env", ["npx", "-y", package] + args, env)
        case .uvx(let package, let args, let env):
            return ("/usr/bin/env", ["uvx", package] + args, env)
        case .binary(let path, let args, let env):
            return (path, args, env)
        case .custom(let command, let args, let env):
            return (command, args, env)
        }
    }

    // MARK: - JSON-RPC Framing

    private func sendRequest(key: String, method: String, params: [String: JSONValue])
        async throws -> JSONValue
    {
        guard sessions[key] != nil else { throw ACPError.streamClosed }

        let id = nextRequestId(key: key)
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(params)
        ]
        try writeFrame(key: key, frame: .object(frame))
        logger.info("[ACP] → \(method, privacy: .public) id=\(id) key=\(key, privacy: .public)")

        return try await withCheckedThrowingContinuation { cont in
            mutateSession(key) { $0.pending[id] = cont }
        }
    }

    private func sendResult(key: String, id: JSONValue, result: JSONValue) {
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ]
        try? writeFrame(key: key, frame: .object(frame))
    }

    private func sendError(key: String, id: JSONValue, code: Int, message: String) {
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message)
            ])
        ]
        try? writeFrame(key: key, frame: .object(frame))
    }

    private func writeFrame(key: String, frame: JSONValue) throws {
        guard let entry = sessions[key] else { throw ACPError.streamClosed }
        let data = try JSONEncoder().encode(frame)
        var line = data
        line.append(0x0A)
        try entry.stdin.write(contentsOf: line)
    }

    private func nextRequestId(key: String) -> Int {
        var id = 0
        mutateSession(key) { entry in
            id = entry.nextId
            entry.nextId += 1
        }
        return id
    }

    private func mutateSession(_ key: String, _ mutate: (inout SessionEntry) -> Void) {
        guard var entry = sessions[key] else { return }
        mutate(&entry)
        sessions[key] = entry
    }

    // MARK: - Read Loop
    //
    // We deliberately avoid `FileHandle.bytes.lines`: in practice that
    // AsyncSequence does not reliably drain Pipe-backed stdout on Darwin —
    // bytes can sit indefinitely until the writer closes the pipe. Instead we
    // use `readabilityHandler`, which is GCD-backed and fires as soon as data
    // arrives, and split into newline-delimited frames ourselves.

    private static func spawnStdoutReader(
        key: String,
        stdout: FileHandle,
        service: ACPService
    ) -> Task<Void, Never> {
        let chunkStream = AsyncStream<Data> { continuation in
            stdout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                stdout.readabilityHandler = nil
            }
        }

        return Task.detached { [weak service] in
            await service?.logReaderStarted(key: key)
            var buffer = Data()
            for await chunk in chunkStream {
                if Task.isCancelled {
                    await service?.logReaderCancelled(key: key)
                    stdout.readabilityHandler = nil
                    return
                }
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8) else { continue }
                    await service?.deliverStdoutLine(key: key, line: line, data: lineData)
                }
            }
            await service?.logReaderEOF(key: key)
        }
    }

    fileprivate func logReaderStarted(key: String) {
        logger.info("[ACP] read loop started for key=\(key, privacy: .public)")
    }
    fileprivate func logReaderCancelled(key: String) {
        logger.info("[ACP] read loop cancelled for key=\(key, privacy: .public)")
    }
    fileprivate func logReaderEOF(key: String) {
        logger.info("[ACP] read loop EOF for key=\(key, privacy: .public)")
    }
    fileprivate func logReaderError(error: Error) {
        logger.warning("[ACP] read loop error: \(error.localizedDescription, privacy: .public)")
    }

    fileprivate func deliverStdoutLine(key: String, line: String, data: Data) async {
        // Resolve the latest canonical key in case the entry has been
        // re-keyed (bootstrap key → agent sessionId).
        let resolved = aliasToCanonical[key] ?? key
        logger.info("[ACP][stdout] \(line.prefix(400), privacy: .public)")
        await handleIncoming(key: resolved, data: data)
    }

    private func handleIncoming(key: String, data: Data) async {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            logger.warning("[ACP] decode failed: \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            return
        }
        guard let obj = value.objectValue else { return }

        // Response (has "id" and "result"/"error", no "method").
        if obj["method"] == nil, let idVal = obj["id"], let idInt = idVal.intValue {
            resolveResponse(key: key, id: idInt, body: obj)
            return
        }

        // Request or notification (has "method").
        guard let method = obj["method"]?.stringValue else { return }
        let params = obj["params"] ?? .null

        if let idVal = obj["id"] {
            await handleAgentRequest(key: key, id: idVal, method: method, params: params)
        } else {
            handleAgentNotification(key: key, method: method, params: params)
        }
    }

    private func resolveResponse(key: String, id: Int, body: [String: JSONValue]) {
        var cont: CheckedContinuation<JSONValue, Error>?
        mutateSession(key) { entry in
            cont = entry.pending.removeValue(forKey: id)
        }
        guard let cont else {
            logger.warning("[ACP] ← response id=\(id) had no pending continuation key=\(key, privacy: .public)")
            return
        }
        if let err = body["error"]?.objectValue {
            let msg = err["message"]?.stringValue ?? "ACP error"
            let code = err["code"]?.intValue ?? -1
            logger.error("[ACP] ← error id=\(id) code=\(code) msg=\(msg, privacy: .public)")
            cont.resume(throwing: ACPError.agentError(code: code, message: msg))
        } else {
            let result = body["result"] ?? .null
            logger.info("[ACP] ← ok id=\(id) result=\(result.shortDescription, privacy: .public)")
            cont.resume(returning: result)
        }
    }

    // MARK: - Agent Notifications

    private func handleAgentNotification(key: String, method: String, params: JSONValue) {
        switch method {
        case "session/update":
            guard sessions[key]?.acceptingUpdates == true else {
                let kind = params.objectValue?["update"]?.objectValue?["sessionUpdate"]?.stringValue ?? "<unknown>"
                logger.info("[ACP] ⟵ pre-prompt session/update dropped kind=\(kind, privacy: .public)")
                return
            }
            handleSessionUpdate(key: key, params: params)
        default:
            logger.warning("[ACP] ⟵ unknown notification: \(method, privacy: .public)")
        }
    }

    private func handleSessionUpdate(key: String, params: JSONValue) {
        guard let p = params.objectValue,
              let update = p["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue,
              let continuation = sessions[key]?.continuation else {
            logger.warning("[ACP] session/update missing fields or no continuation key=\(key, privacy: .public)")
            return
        }

        switch kind {
        case "agent_message_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue {
                logger.info("[ACP] ⟵ agent_message_chunk len=\(text.count)")
                continuation.yield(.unknown(Self.textDeltaFrame(text)))
            } else {
                logger.warning("[ACP] agent_message_chunk had no text content")
            }

        case "agent_thought_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue {
                logger.info("[ACP] ⟵ agent_thought_chunk len=\(text.count)")
                continuation.yield(.unknown(Self.thinkingDeltaFrame(text)))
            }

        case "plan":
            let entries = update["entries"]?.arrayValue?.count ?? 0
            logger.info("[ACP] ⟵ plan entries=\(entries)")
            handlePlanUpdate(key: key, update: update, continuation: continuation)

        case "tool_call":
            handleToolCall(key: key, update: update, continuation: continuation)

        case "tool_call_update":
            handleToolCallUpdate(key: key, update: update, continuation: continuation)

        default:
            logger.warning("[ACP] ⟵ unhandled sessionUpdate kind: \(kind, privacy: .public)")
        }
    }

    private func handlePlanUpdate(key: String, update: [String: JSONValue],
                                   continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let entries = update["entries"]?.arrayValue else { return }

        var markdown = "# Plan\n\n"
        for entry in entries {
            guard let obj = entry.objectValue else { continue }
            let status = obj["status"]?.stringValue ?? "pending"
            let content = obj["content"]?.stringValue ?? ""
            let mark: String
            switch status {
            case "completed": mark = "- [x] "
            case "in_progress": mark = "- [~] "
            default: mark = "- [ ] "
            }
            markdown += "\(mark)\(content)\n"
        }

        let planId = sessions[key]?.planSyntheticId ?? "acp-plan"
        continuation.yield(.assistant(AssistantMessage(
            role: "assistant",
            content: [.toolUse(
                id: planId,
                name: "ExitPlanMode",
                input: ["plan": .string(markdown)]
            )]
        )))
        mutateSession(key) { $0.planEmitted = true }
    }

    private func handleToolCall(key: String, update: [String: JSONValue],
                                 continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let toolCallId = update["toolCallId"]?.stringValue else {
            logger.warning("[ACP] tool_call missing toolCallId")
            return
        }
        let title = update["title"]?.stringValue ?? update["kind"]?.stringValue ?? "tool"
        let kind = update["kind"]?.stringValue
        let rawInput = update["rawInput"]?.objectValue ?? [:]
        let normalized = Self.normalizeToolCall(kind: kind, title: title, update: update, rawInput: rawInput)
        let mcpTag = (normalized.name.contains("context7") || normalized.name.contains("mcp_") || title.contains("MCP")) ? " [MCP]" : ""
        logger.info("[ACP] ⟵ tool_call\(mcpTag, privacy: .public) id=\(toolCallId, privacy: .public) name=\(normalized.name, privacy: .public) title=\(title, privacy: .public) kind=\(kind ?? "<nil>", privacy: .public) inputKeys=[\(normalized.input.keys.sorted().joined(separator: ","), privacy: .public)]")

        mutateSession(key) { $0.liveToolCalls.insert(toolCallId) }

        continuation.yield(.assistant(AssistantMessage(
            role: "assistant",
            content: [.toolUse(id: toolCallId, name: normalized.name, input: normalized.input)]
        )))
    }

    private func handleToolCallUpdate(key: String, update: [String: JSONValue],
                                       continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let toolCallId = update["toolCallId"]?.stringValue else {
            logger.warning("[ACP] tool_call_update missing toolCallId")
            return
        }
        let status = update["status"]?.stringValue ?? "completed"
        logger.info("[ACP] ⟵ tool_call_update id=\(toolCallId, privacy: .public) status=\(status, privacy: .public)")

        // If the update carries diff content (ACP allows the agent to attach
        // diffs on either tool_call or tool_call_update), re-emit a toolUse
        // with the merged input so AppState can persist the file edit when the
        // result lands. AppState merges by toolCallId, so this patches the
        // existing block in place rather than appending a duplicate.
        let diffEntries = Self.diffEntries(in: update)
        if !diffEntries.isEmpty {
            let kind = update["kind"]?.stringValue
            let title = update["title"]?.stringValue ?? kind ?? "tool"
            let rawInput = update["rawInput"]?.objectValue ?? [:]
            let normalized = Self.normalizeToolCall(kind: kind ?? "edit", title: title, update: update, rawInput: rawInput)
            logger.info("[ACP] ⟵ tool_call_update id=\(toolCallId, privacy: .public) carrying diffs=\(diffEntries.count) → patching toolUse name=\(normalized.name, privacy: .public)")
            continuation.yield(.assistant(AssistantMessage(
                role: "assistant",
                content: [.toolUse(id: toolCallId, name: normalized.name, input: normalized.input)]
            )))
        }

        // Compose tool result text from rawOutput or content[]
        var resultText = ""
        if let raw = update["rawOutput"] {
            if let s = raw.stringValue { resultText = s }
            else if let data = try? JSONEncoder().encode(raw),
                    let s = String(data: data, encoding: .utf8) { resultText = s }
        } else if let content = update["content"]?.arrayValue {
            resultText = content.compactMap { entry -> String? in
                guard let obj = entry.objectValue else { return nil }
                if obj["type"]?.stringValue == "content",
                   let inner = obj["content"]?.objectValue,
                   inner["type"]?.stringValue == "text" {
                    return inner["text"]?.stringValue
                }
                return obj["text"]?.stringValue
            }.joined(separator: "\n")
        }

        let isError = status == "failed"
        continuation.yield(.user(UserMessage(
            toolUseId: toolCallId,
            content: resultText.isEmpty ? (isError ? "Tool failed" : "Done") : resultText,
            isError: isError
        )))
    }

    // MARK: - Agent Requests (server-initiated)

    private func handleAgentRequest(key: String, id: JSONValue, method: String, params: JSONValue) async {
        logger.info("[ACP] ⟵ agent-request \(method, privacy: .public) key=\(key, privacy: .public)")
        switch method {
        case "fs/read_text_file":
            await handleFsReadTextFile(key: key, id: id, params: params)
        case "fs/write_text_file":
            await handleFsWriteTextFile(key: key, id: id, params: params)
        case "session/request_permission":
            await handleSessionRequestPermission(key: key, id: id, params: params)
        default:
            logger.warning("[ACP] unsupported agent-request: \(method, privacy: .public)")
            sendError(key: key, id: id, code: -32601, message: "Method not supported: \(method)")
        }
    }

    private func handleFsReadTextFile(key: String, id: JSONValue, params: JSONValue) async {
        guard let path = params.objectValue?["path"]?.stringValue else {
            sendError(key: key, id: id, code: -32602, message: "Missing path")
            return
        }
        do {
            let line = params.objectValue?["line"]?.intValue
            let limit = params.objectValue?["limit"]?.intValue
            let content = try Self.readTextFile(path: path, line: line, limit: limit)
            sendResult(key: key, id: id, result: .object(["content": .string(content)]))
        } catch {
            sendError(key: key, id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleFsWriteTextFile(key: String, id: JSONValue, params: JSONValue) async {
        guard let path = params.objectValue?["path"]?.stringValue,
              let content = params.objectValue?["content"]?.stringValue else {
            sendError(key: key, id: id, code: -32602, message: "Missing path or content")
            return
        }
        do {
            try Self.writeTextFile(path: path, content: content)
            sendResult(key: key, id: id, result: .object([:]))
        } catch {
            sendError(key: key, id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleSessionRequestPermission(key: String, id: JSONValue, params: JSONValue) async {
        guard let entry = sessions[key] else {
            logger.warning("[ACP] permission request arrived for closed session")
            sendError(key: key, id: id, code: -32000, message: "Session closed")
            return
        }
        let toolCall = params.objectValue?["toolCall"]?.objectValue ?? [:]
        let toolCallId = toolCall["toolCallId"]?.stringValue ?? UUID().uuidString
        let toolName = toolCall["title"]?.stringValue ?? toolCall["kind"]?.stringValue ?? "tool"
        let toolInput = toolCall["rawInput"]?.objectValue ?? [:]
        logger.info("[ACP] permission request tool=\(toolName, privacy: .public) id=\(toolCallId, privacy: .public)")

        guard let server = permissionServer else {
            let optionId = params.objectValue?["options"]?.arrayValue?
                .first(where: { $0.objectValue?["kind"]?.stringValue == "allow_once" })?
                .objectValue?["optionId"]?.stringValue ?? "allow"
            logger.warning("[ACP] no permission server — auto-allowing \(toolName, privacy: .public) via optionId=\(optionId, privacy: .public)")
            sendResult(key: key, id: id, result: .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionId)
                ])
            ]))
            return
        }

        let decision = await server.requestDecision(
            toolUseId: toolCallId,
            sessionId: entry.agentSessionId,
            toolName: toolName,
            toolInput: toolInput,
            mode: nil
        )
        logger.info("[ACP] permission decision tool=\(toolName, privacy: .public) decision=\(String(describing: decision), privacy: .public)")

        let options = params.objectValue?["options"]?.arrayValue ?? []
        let wantKind: String
        switch decision {
        case .allow, .allowSessionTool, .allowAlwaysCommand, .allowAndSetMode:
            wantKind = "allow_once"
        case .deny, .denyWithReason:
            wantKind = "reject_once"
        }
        let chosen = options.first { $0.objectValue?["kind"]?.stringValue == wantKind }
            ?? options.first
        let optionId = chosen?.objectValue?["optionId"]?.stringValue ?? wantKind
        logger.info("[ACP] permission reply wantKind=\(wantKind, privacy: .public) optionId=\(optionId, privacy: .public)")

        sendResult(key: key, id: id, result: .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionId)
            ])
        ]))
    }

    // MARK: - File Helpers

    private static func readTextFile(path: String, line: Int?, limit: Int?) throws -> String {
        let url = URL(fileURLWithPath: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        if line == nil && limit == nil { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (line ?? 1) - 1)
        let end = limit.map { min(lines.count, start + $0) } ?? lines.count
        guard start < lines.count else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }

    private static func writeTextFile(path: String, content: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Capability Helpers

    private func agentSupportsLoadSession(_ initResult: JSONValue) -> Bool {
        initResult.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue ?? false
    }

    private func agentSupportsMCPTransport(_ transport: String, initResult: JSONValue) -> Bool {
        guard transport == "http" || transport == "sse" else { return true }
        return initResult
            .objectValue?["agentCapabilities"]?
            .objectValue?["mcpCapabilities"]?
            .objectValue?[transport]?
            .boolValue ?? false
    }

    private func supportedMCPServers(_ servers: [JSONValue], initResult: JSONValue) -> [JSONValue] {
        let mcpCaps = initResult.objectValue?["agentCapabilities"]?.objectValue?["mcpCapabilities"]
        logger.info("[ACP-MCP] agent advertised mcpCapabilities=\(mcpCaps?.shortDescription ?? "<nil>", privacy: .public) (http=\(mcpCaps?.objectValue?["http"]?.boolValue == true) sse=\(mcpCaps?.objectValue?["sse"]?.boolValue == true))")

        var supported: [JSONValue] = []
        var dropped: [String] = []

        for server in servers {
            let obj = server.objectValue
            let transport = obj?["type"]?.stringValue ?? "stdio"
            let name = obj?["name"]?.stringValue ?? "<unnamed>"
            if agentSupportsMCPTransport(transport, initResult: initResult) {
                logger.info("[ACP-MCP] passing entry name=\(name, privacy: .public) transport=\(transport, privacy: .public)")
                supported.append(server)
            } else {
                logger.info("[ACP-MCP] dropping entry name=\(name, privacy: .public) transport=\(transport, privacy: .public) — agent doesn't advertise capability")
                dropped.append("\(name):\(transport)")
            }
        }

        if !dropped.isEmpty {
            logger.info("[ACP-MCP] dropping unsupported MCP transports: \(dropped.joined(separator: ", "), privacy: .public)")
        }
        logger.info("[ACP-MCP] passing \(supported.count, privacy: .public)/\(servers.count, privacy: .public) mcpServers after initialize capability check")
        return supported
    }

    /// Scans a `session/new` (or `session/load`) response for the first
    /// `SessionConfigOption` with `category: "model"` and `type: "select"`,
    /// flattening grouped options.
    private static func parseModelConfig(from result: JSONValue) -> ACPModelConfig? {
        guard let configOptions = result.objectValue?["configOptions"]?.arrayValue else { return nil }
        for option in configOptions {
            guard let obj = option.objectValue,
                  obj["category"]?.stringValue == "model",
                  obj["type"]?.stringValue == "select",
                  let configId = obj["id"]?.stringValue,
                  let opts = obj["options"]?.arrayValue
            else { continue }

            var flattened: [ACPModelOption] = []
            for entry in opts {
                guard let entryObj = entry.objectValue else { continue }
                if let groupOpts = entryObj["options"]?.arrayValue {
                    for groupEntry in groupOpts {
                        if let parsed = parseSelectOption(groupEntry) {
                            flattened.append(parsed)
                        }
                    }
                } else if let parsed = parseSelectOption(entry) {
                    flattened.append(parsed)
                }
            }
            guard !flattened.isEmpty else { continue }
            return ACPModelConfig(
                configId: configId,
                currentValue: obj["currentValue"]?.stringValue,
                options: flattened
            )
        }
        return nil
    }

    // MARK: - Tool Call Normalization
    //
    // ACP `tool_call` notifications expose two views of a tool invocation:
    // a machine-readable `kind` ("edit", "execute", "read", …) and a
    // human-readable `title`. The agent's `rawInput` is opaque (each agent
    // chooses its own schema), but the optional `content` array surfaces
    // structured `diff` entries (`{path, oldText, newText}`) that we can
    // translate into the Claude-shaped `Edit`/`Write`/`MultiEdit` input keys
    // the rest of RxCode (sidebar persistence, diff renderer, plan card)
    // already understands.

    private struct NormalizedToolCall {
        let name: String
        let input: [String: JSONValue]
    }

    /// Extracts `{type: "diff", path, oldText, newText}` entries from a
    /// session/update payload's `content` array. Returns `[]` for non-edit
    /// kinds or absent content.
    private static func diffEntries(in update: [String: JSONValue]) -> [(path: String, oldText: String?, newText: String)] {
        guard let content = update["content"]?.arrayValue else { return [] }
        var out: [(path: String, oldText: String?, newText: String)] = []
        for entry in content {
            guard let obj = entry.objectValue,
                  obj["type"]?.stringValue == "diff",
                  let path = obj["path"]?.stringValue,
                  let newText = obj["newText"]?.stringValue
            else { continue }
            let oldText = obj["oldText"]?.stringValue
            out.append((path: path, oldText: oldText, newText: newText))
        }
        return out
    }

    /// Translates an ACP tool_call payload into a Claude-shaped (name, input).
    /// Edit-kind calls with diff content become `Edit`/`Write`/`MultiEdit` so
    /// `ChatMessage.fileEditHunks` and `editedFilePath` can extract the path
    /// and hunks for sidebar persistence. Other kinds fall back to the agent's
    /// title + rawInput unchanged.
    private static func normalizeToolCall(
        kind: String?,
        title: String,
        update: [String: JSONValue],
        rawInput: [String: JSONValue]
    ) -> NormalizedToolCall {
        let normalizedKind = (kind ?? "").lowercased()
        let diffs = diffEntries(in: update)
        if normalizedKind == "edit" || !diffs.isEmpty {
            if !diffs.isEmpty {
                if diffs.count == 1 {
                    let only = diffs[0]
                    let oldText = only.oldText ?? ""
                    if oldText.isEmpty {
                        return NormalizedToolCall(
                            name: "Write",
                            input: [
                                "file_path": .string(only.path),
                                "content": .string(only.newText)
                            ]
                        )
                    }
                    return NormalizedToolCall(
                        name: "Edit",
                        input: [
                            "file_path": .string(only.path),
                            "old_string": .string(oldText),
                            "new_string": .string(only.newText)
                        ]
                    )
                }
                let primaryPath = diffs.first!.path
                let edits: [JSONValue] = diffs.filter { $0.path == primaryPath }.map { d in
                    .object([
                        "old_string": .string(d.oldText ?? ""),
                        "new_string": .string(d.newText)
                    ])
                }
                return NormalizedToolCall(
                    name: "MultiEdit",
                    input: [
                        "file_path": .string(primaryPath),
                        "edits": .array(edits)
                    ]
                )
            }
            var input = rawInput
            if input["file_path"] == nil,
               let path = (update["locations"]?.arrayValue?.first?.objectValue?["path"]?.stringValue) {
                input["file_path"] = .string(path)
            }
            return NormalizedToolCall(name: "Edit", input: input)
        }

        return NormalizedToolCall(name: title, input: rawInput)
    }

    /// Wraps a text chunk in the same raw-event shape Claude's CLI emits, so
    /// `AppState.handlePartialEvent` accumulates it into `state.textDeltaBuffer`.
    private static func textDeltaFrame(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": text]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    private static func thinkingDeltaFrame(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "thinking_delta", "thinking": text]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    private static func parseSelectOption(_ value: JSONValue) -> ACPModelOption? {
        guard let obj = value.objectValue,
              let val = obj["value"]?.stringValue,
              let name = obj["name"]?.stringValue
        else { return nil }
        return ACPModelOption(
            value: val,
            name: name,
            description: obj["description"]?.stringValue
        )
    }

    private static func modelListDescription(_ options: [ACPModelOption]) -> String {
        options.map { option in
            option.name == option.value ? option.value : "\(option.value) (\(option.name))"
        }.joined(separator: ", ")
    }

    // MARK: - Process Lifecycle

    private func startStderrReader(key: String, stderr: FileHandle) {
        let chunkStream = AsyncStream<Data> { continuation in
            stderr.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                stderr.readabilityHandler = nil
            }
        }

        Task.detached { [weak self] in
            var buffer = Data()
            for await chunk in chunkStream {
                if Task.isCancelled {
                    stderr.readabilityHandler = nil
                    return
                }
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    await self?.appendStderr(key: key, line: line)
                }
            }
        }
    }

    private func appendStderr(key: String, line: String) {
        let resolved = aliasToCanonical[key] ?? key
        mutateSession(resolved) { $0.stderr += line + "\n" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            logger.info("[ACP][stderr] \(trimmed, privacy: .public)")
        }
    }

    private func handleProcessExit(key: String) {
        let resolved = aliasToCanonical[key] ?? key
        guard let entry = sessions[resolved] else { return }
        logger.info("[ACP] process exit pid=\(entry.process.processIdentifier) status=\(entry.process.terminationStatus) reason=\(String(describing: entry.process.terminationReason.rawValue), privacy: .public) pending=\(entry.pending.count) client=\(entry.spec.displayName, privacy: .public)")
        for (_, cont) in entry.pending {
            cont.resume(throwing: ACPError.processExited(code: entry.process.terminationStatus))
        }
        mutateSession(resolved) { $0.pending.removeAll() }
        entry.continuation?.finish()
        // Drop the entire pool entry — once the agent process is gone we
        // can't reuse it for the next turn anyway. The next `send()` will
        // spawn fresh.
        killSession(key: resolved)
    }
}

// MARK: - Errors

enum ACPError: LocalizedError {
    case streamClosed
    case protocolMismatch(String)
    case agentError(code: Int, message: String)
    case processExited(code: Int32)
    case probeTimeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .streamClosed: return "ACP stream closed"
        case .protocolMismatch(let msg): return "ACP protocol mismatch: \(msg)"
        case .agentError(let code, let msg): return "ACP agent error \(code): \(msg)"
        case .processExited(let code): return "ACP agent exited (code \(code))"
        case .probeTimeout(let s): return "ACP agent did not respond within \(s)s"
        }
    }
}

// MARK: - JSONValue Conveniences

extension JSONValue {
    fileprivate nonisolated var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    fileprivate nonisolated var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    fileprivate nonisolated var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    fileprivate nonisolated var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    fileprivate nonisolated var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }
    fileprivate nonisolated var shortDescription: String {
        switch self {
        case .object(let o): return "object(\(o.count) keys)"
        case .array(let a): return "array(\(a.count))"
        case .string(let s): return s.prefix(80).description
        case .number(let n): return "\(n)"
        case .bool(let b): return "\(b)"
        case .null: return "null"
        }
    }
}

// MARK: - AgentBackend Conformance

extension ACPService: AgentBackend {
    nonisolated var provider: AgentProvider { .acp }
    nonisolated var staticCapabilities: CapabilitySet { AgentProvider.acp.staticCapabilities }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        guard let spec = request.acpSpec else {
            return AsyncStream<StreamEvent> { c in
                c.yield(.user(UserMessage(
                    toolUseId: nil,
                    content: "No ACP client configured. Add one in Settings → ACP Clients.",
                    isError: true
                )))
                c.yield(.result(ResultEvent(
                    durationMs: nil, totalCostUsd: nil,
                    sessionId: request.sessionId ?? request.clientSessionKey,
                    isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                )))
                c.finish()
            }
        }
        return send(
            streamId: request.streamId,
            prompt: request.prompt,
            cwd: request.cwd,
            sessionId: request.sessionId,
            model: request.model,
            spec: spec,
            permissionMode: request.permissionMode,
            clientSessionKey: request.clientSessionKey,
            mcpServers: request.acpMCPServers
        )
    }
}
