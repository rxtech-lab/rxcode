import Foundation
import RxCodeCore
import os

// MARK: - Turn Lifecycle & Model Probing

extension ACPService {

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

    func handleStreamTermination(streamId: UUID) {
        logger.info("[ACP] stream consumer detached streamId=\(streamId.uuidString, privacy: .public)")
        finalize(streamId: streamId)
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

    func runProbeSequence(
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

    func runTurn(
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

    func runFreshTurn(
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

    func runReusedTurn(
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
    func applyModelSelection(
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

    func runPrompt(
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

    func heartbeatTick(displayName: String, elapsed: Int, launchKind: String) {
        let hint = launchKind == "npx"
            ? " (npx cold-start is ~10s; first run may install the package)"
            : ""
        logger.notice("[ACP] still waiting for \(displayName, privacy: .public) response after \(elapsed)s\(hint, privacy: .public)")
    }
}
