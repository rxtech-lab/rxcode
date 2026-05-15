import Foundation
import RxCodeCore
import os

// MARK: - ACPService
//
// Speaks the Agent Client Protocol (https://agentclientprotocol.com) over
// newline-delimited JSON-RPC on a child process's stdio.
//
// One ACPService instance hosts many concurrent streams. Each stream owns a
// dedicated agent subprocess for its turn — the simplest mapping that mirrors
// `ClaudeService`'s one-process-per-prompt model. A future optimization could
// pool processes per (cwd, clientSpec) since ACP supports `session/load`.

actor ACPService {

    private let logger = Logger(subsystem: "com.claudework", category: "ACPService")

    private struct StreamEntry {
        let process: Process
        let stdin: FileHandle
        var nextId: Int = 1
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var agentSessionId: String?
        var continuation: AsyncStream<StreamEvent>.Continuation?
        var spec: ACPClientSpec
        var cwd: String
        var clientSessionKey: String
        var stderr: String = ""
        /// `tool_call.toolCallId` → synthesized RxCode ToolCall id (same string).
        var liveToolCalls: Set<String> = []
        /// Plan card uses a stable synthetic id per stream so successive `plan` updates replace the same card.
        let planSyntheticId: String = "acp-plan-\(UUID().uuidString)"
        var planEmitted: Bool = false
        /// `SessionConfigId` of the model selector advertised by the agent's
        /// `session/new` response, if any. Cached so the turn can issue
        /// `session/set_config_option` to switch models.
        var modelConfigId: String?
        /// Toggled on just before `session/prompt` is sent. Agents like
        /// OpenCode replay the historical conversation as `session/update`
        /// notifications during `session/load`; we discard those so they don't
        /// get rendered as live messages.
        var acceptingUpdates: Bool = false
    }

    private var streams: [UUID: StreamEntry] = [:]
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
        clientSessionKey: String
    ) -> AsyncStream<StreamEvent> {
        logger.info("[ACP] send streamId=\(streamId.uuidString, privacy: .public) client=\(spec.displayName, privacy: .public) launch=\(spec.launch.displayKind, privacy: .public) model=\(model ?? "<default>", privacy: .public) sessionId=\(sessionId ?? "<new>", privacy: .public) mode=\(String(describing: permissionMode), privacy: .public) cwd=\(cwd, privacy: .public) promptLen=\(prompt.count)")
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
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.handleStreamTermination(streamId: streamId) }
            }
        }
    }

    func finalize(streamId: UUID) {
        guard var entry = streams.removeValue(forKey: streamId) else { return }
        logger.info("[ACP] finalize streamId=\(streamId.uuidString, privacy: .public) pid=\(entry.process.processIdentifier) pending=\(entry.pending.count) running=\(entry.process.isRunning)")
        try? entry.stdin.close()
        if entry.process.isRunning {
            entry.process.terminate()
        }
        for (_, cont) in entry.pending {
            cont.resume(throwing: ACPError.streamClosed)
        }
        entry.pending.removeAll()
    }

    func handleStreamTermination(streamId: UUID) {
        logger.info("[ACP] stream consumer detached streamId=\(streamId.uuidString, privacy: .public)")
        finalize(streamId: streamId)
    }

    func cancel(streamId: UUID) {
        // Attempt graceful cancel via session/cancel notification, then kill the process.
        if let entry = streams[streamId], let sid = entry.agentSessionId {
            let frame: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": ["sessionId": sid]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: frame),
               let line = String(data: data, encoding: .utf8) {
                _ = try? entry.stdin.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        finalize(streamId: streamId)
    }

    func consumeStderr(for streamId: UUID) -> String? {
        guard let entry = streams[streamId] else { return nil }
        let trimmed = entry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cleanup() {
        for (id, _) in streams {
            finalize(streamId: id)
        }
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
        logger.info("[ACP] probe start: \(spec.displayName, privacy: .public) (launch=\(spec.launch.displayKind, privacy: .public)) cwd=\(cwd, privacy: .public)")

        let (process, stdin, stdout, stderr) = try await spawn(spec: spec, model: nil, cwd: cwd)
        logger.info("[ACP] probe spawned pid=\(process.processIdentifier) for \(spec.displayName, privacy: .public)")

        let entry = StreamEntry(
            process: process,
            stdin: stdin,
            spec: spec,
            cwd: cwd,
            clientSessionKey: ""
        )
        streams[streamId] = entry

        startStderrReader(streamId: streamId, stderr: stderr)
        let readerTask = Self.spawnStdoutReader(streamId: streamId, stdout: stdout, service: self)
        process.terminationHandler = { [weak self] _ in
            Task.detached { await self?.handleProcessExit(streamId: streamId) }
        }

        do {
            let result = try await withThrowingTaskGroup(of: ACPModelConfig?.self) { group in
                group.addTask {
                    try await self.runProbeSequence(streamId: streamId, spec: spec, cwd: cwd)
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
            finalize(streamId: streamId)
            return result
        } catch {
            let stderrSnapshot = streams[streamId]?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderrSnapshot.isEmpty {
                logger.error("[ACP] probe stderr for \(spec.displayName, privacy: .public): \(stderrSnapshot, privacy: .public)")
            }
            readerTask.cancel()
            finalize(streamId: streamId)
            throw error
        }
    }

    private func runProbeSequence(
        streamId: UUID,
        spec: ACPClientSpec,
        cwd: String
    ) async throws -> ACPModelConfig? {
        logger.info("[ACP] probe → initialize \(spec.displayName, privacy: .public)")
        _ = try await sendRequest(
            streamId: streamId,
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
            streamId: streamId,
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
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async {
        do {
            let (process, stdin, stdout, stderr) = try await spawn(spec: spec, model: model, cwd: cwd)
            var entry = StreamEntry(
                process: process,
                stdin: stdin,
                spec: spec,
                cwd: cwd,
                clientSessionKey: clientSessionKey
            )
            entry.continuation = continuation
            streams[streamId] = entry

            // Start background readers detached so they don't fight the writer
            // for ACPService actor reentrance — they only hop onto the actor
            // when delivering a line.
            startStderrReader(streamId: streamId, stderr: stderr)
            let readerTask = Self.spawnStdoutReader(streamId: streamId, stdout: stdout, service: self)
            process.terminationHandler = { [weak self] _ in
                Task.detached { await self?.handleProcessExit(streamId: streamId) }
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
                streamId: streamId,
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

            // Surface the agent identity as a system event so the chat header
            // matches the Claude path.
            continuation.yield(.system(SystemEvent(
                subtype: "init",
                sessionId: incomingSessionId,
                tools: nil,
                model: model,
                claudeCodeVersion: nil
            )))

            // 2. Always `session/new`. We could `session/load` here if the agent
            // advertises `loadSession`, but ACP's load-replay is only useful
            // when the same agent *process* is being reattached. Our current
            // architecture spawns a fresh subprocess per turn, so `session/load`
            // on agents that persist sessions to disk (Gemini CLI) makes them
            // re-emit the persisted conversation during the next `session/prompt`,
            // which surfaces in the UI as prior answers being prepended to new
            // ones. Each turn therefore starts a fresh ACP session; conversation
            // continuity is preserved by RxCode's chat history, not by the agent.
            let agentSessionId: String
            var modelConfig: ACPModelConfig?
            let sessionMethod = "session/new"
            let newParams: [String: JSONValue] = [
                "cwd": .string(cwd),
                "mcpServers": .array([])
            ]
            let newResult = try await sendRequest(streamId: streamId, method: "session/new", params: newParams)
            guard let sid = newResult.objectValue?["sessionId"]?.stringValue else {
                throw ACPError.protocolMismatch("session/new returned no sessionId")
            }
            modelConfig = Self.parseModelConfig(from: newResult)
            agentSessionId = sid
            _ = incomingSessionId // intentionally unused — see comment above
            mutateStream(streamId) {
                $0.agentSessionId = agentSessionId
                $0.modelConfigId = modelConfig?.configId
            }

            // Tell AppState about the discovered model list so it can refresh
            // the picker and persist it to disk.
            if let modelConfig {
                logger.info("[ACP] discovered model selector for \(spec.displayName, privacy: .public) via \(sessionMethod, privacy: .public) configId=\(modelConfig.configId, privacy: .public) current=\(modelConfig.currentValue ?? "nil", privacy: .public) models=\(modelConfig.options.count) [\(Self.modelListDescription(modelConfig.options), privacy: .public)]")
                continuation.yield(.acpModelsDiscovered(ACPModelsDiscoveredEvent(
                    clientId: spec.id,
                    config: modelConfig
                )))
            } else {
                logger.info("[ACP] no model selector discovered for \(spec.displayName, privacy: .public) via \(sessionMethod, privacy: .public)")
            }

            // Apply the user's model choice via the spec-compliant route when
            // the agent advertised a selector. Env-var-at-spawn covers the
            // fallback case for older agents.
            if let modelConfig,
               let model,
               !model.isEmpty,
               modelConfig.options.contains(where: { $0.value == model }),
               modelConfig.currentValue != model {
                do {
                    _ = try await sendRequest(
                        streamId: streamId,
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

            // Emit the agent's session id so the chat UI replaces its pending placeholder.
            continuation.yield(.system(SystemEvent(
                subtype: "session_started",
                sessionId: agentSessionId,
                tools: nil,
                model: model,
                claudeCodeVersion: nil
            )))

            // 3. session/prompt — blocks until the turn completes.
            // Flip the gate AFTER the optional `session/set_config_option`
            // exchange so we don't accept stray updates before the prompt is
            // actually in flight.
            mutateStream(streamId) { $0.acceptingUpdates = true }
            let promptResult = try await sendRequest(
                streamId: streamId,
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

            readerTask.cancel()
            continuation.finish()
            finalize(streamId: streamId)
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
            // `npx -y <package>` so it runs without an install prompt.
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

    private func sendRequest(streamId: UUID, method: String, params: [String: JSONValue])
        async throws -> JSONValue
    {
        guard streams[streamId] != nil else { throw ACPError.streamClosed }

        let id = nextRequestId(streamId: streamId)
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(params)
        ]
        try writeFrame(streamId: streamId, frame: .object(frame))
        logger.info("[ACP] → \(method, privacy: .public) id=\(id) stream=\(streamId.uuidString.prefix(8), privacy: .public)")

        return try await withCheckedThrowingContinuation { cont in
            mutateStream(streamId) { $0.pending[id] = cont }
        }
    }

    private func sendResult(streamId: UUID, id: JSONValue, result: JSONValue) {
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ]
        try? writeFrame(streamId: streamId, frame: .object(frame))
    }

    private func sendError(streamId: UUID, id: JSONValue, code: Int, message: String) {
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message)
            ])
        ]
        try? writeFrame(streamId: streamId, frame: .object(frame))
    }

    private func writeFrame(streamId: UUID, frame: JSONValue) throws {
        guard let entry = streams[streamId] else { throw ACPError.streamClosed }
        let data = try JSONEncoder().encode(frame)
        var line = data
        line.append(0x0A) // newline
        try entry.stdin.write(contentsOf: line)
    }

    private func nextRequestId(streamId: UUID) -> Int {
        var id = 0
        mutateStream(streamId) { entry in
            id = entry.nextId
            entry.nextId += 1
        }
        return id
    }

    private func mutateStream(_ streamId: UUID, _ mutate: (inout StreamEntry) -> Void) {
        guard var entry = streams[streamId] else { return }
        mutate(&entry)
        streams[streamId] = entry
    }

    // MARK: - Read Loop
    //
    // We deliberately avoid `FileHandle.bytes.lines`: in practice that
    // AsyncSequence does not reliably drain Pipe-backed stdout on Darwin —
    // bytes can sit indefinitely until the writer closes the pipe. Instead we
    // use `readabilityHandler`, which is GCD-backed and fires as soon as data
    // arrives, and split into newline-delimited frames ourselves.

    private static func spawnStdoutReader(
        streamId: UUID,
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
            let shortId = String(streamId.uuidString.prefix(8))
            await service?.logReaderStarted(shortId: shortId)
            var buffer = Data()
            for await chunk in chunkStream {
                if Task.isCancelled {
                    await service?.logReaderCancelled(shortId: shortId)
                    stdout.readabilityHandler = nil
                    return
                }
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8) else { continue }
                    await service?.deliverStdoutLine(streamId: streamId, line: line, data: lineData)
                }
            }
            await service?.logReaderEOF(shortId: shortId)
        }
    }

    fileprivate func logReaderStarted(shortId: String) {
        logger.info("[ACP] read loop started for stream=\(shortId, privacy: .public)")
    }
    fileprivate func logReaderCancelled(shortId: String) {
        logger.info("[ACP] read loop cancelled for stream=\(shortId, privacy: .public)")
    }
    fileprivate func logReaderEOF(shortId: String) {
        logger.info("[ACP] read loop EOF for stream=\(shortId, privacy: .public)")
    }
    fileprivate func logReaderError(error: Error) {
        logger.warning("[ACP] read loop error: \(error.localizedDescription, privacy: .public)")
    }

    fileprivate func deliverStdoutLine(streamId: UUID, line: String, data: Data) async {
        logger.info("[ACP][stdout] \(line.prefix(400), privacy: .public)")
        await handleIncoming(streamId: streamId, data: data)
    }

    private func handleIncoming(streamId: UUID, data: Data) async {
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
            resolveResponse(streamId: streamId, id: idInt, body: obj)
            return
        }

        // Request or notification (has "method").
        guard let method = obj["method"]?.stringValue else { return }
        let params = obj["params"] ?? .null

        if let idVal = obj["id"] {
            // Server-initiated request: respond.
            await handleAgentRequest(streamId: streamId, id: idVal, method: method, params: params)
        } else {
            // Notification.
            handleAgentNotification(streamId: streamId, method: method, params: params)
        }
    }

    private func resolveResponse(streamId: UUID, id: Int, body: [String: JSONValue]) {
        var cont: CheckedContinuation<JSONValue, Error>?
        mutateStream(streamId) { entry in
            cont = entry.pending.removeValue(forKey: id)
        }
        guard let cont else {
            logger.warning("[ACP] ← response id=\(id) had no pending continuation stream=\(streamId.uuidString.prefix(8), privacy: .public)")
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

    private func handleAgentNotification(streamId: UUID, method: String, params: JSONValue) {
        switch method {
        case "session/update":
            // Drop updates that arrive before `session/prompt` is sent — those
            // are the agent's replay of historical content from `session/load`
            // and would duplicate prior messages in the UI.
            guard streams[streamId]?.acceptingUpdates == true else {
                let kind = params.objectValue?["update"]?.objectValue?["sessionUpdate"]?.stringValue ?? "<unknown>"
                logger.info("[ACP] ⟵ pre-prompt session/update dropped kind=\(kind, privacy: .public)")
                return
            }
            handleSessionUpdate(streamId: streamId, params: params)
        default:
            logger.warning("[ACP] ⟵ unknown notification: \(method, privacy: .public)")
        }
    }

    private func handleSessionUpdate(streamId: UUID, params: JSONValue) {
        guard let p = params.objectValue,
              let update = p["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue,
              let continuation = streams[streamId]?.continuation else {
            logger.warning("[ACP] session/update missing fields or no continuation stream=\(streamId.uuidString.prefix(8), privacy: .public)")
            return
        }

        switch kind {
        case "agent_message_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue {
                logger.info("[ACP] ⟵ agent_message_chunk len=\(text.count)")
                // Route through the Claude `content_block_delta` / `text_delta`
                // pipeline so consecutive chunks accumulate into the same
                // streaming assistant bubble via `state.textDeltaBuffer`. The
                // `.assistant(.text(_))` path only flushes the first chunk per
                // turn (dedup guard in `processStream`), so it was dropping
                // every chunk after the first.
                continuation.yield(.unknown(Self.textDeltaFrame(text)))
            } else {
                logger.warning("[ACP] agent_message_chunk had no text content")
            }

        case "agent_thought_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue {
                logger.info("[ACP] ⟵ agent_thought_chunk len=\(text.count)")
                // Only the `isThinking` flag flip in `handlePartialEvent` is
                // wired up for thinking text; emitting a thinking_delta is
                // enough to surface the "thinking…" indicator in the UI.
                continuation.yield(.unknown(Self.thinkingDeltaFrame(text)))
            }

        case "plan":
            let entries = update["entries"]?.arrayValue?.count ?? 0
            logger.info("[ACP] ⟵ plan entries=\(entries)")
            handlePlanUpdate(streamId: streamId, update: update, continuation: continuation)

        case "tool_call":
            handleToolCall(streamId: streamId, update: update, continuation: continuation)

        case "tool_call_update":
            handleToolCallUpdate(streamId: streamId, update: update, continuation: continuation)

        default:
            logger.warning("[ACP] ⟵ unhandled sessionUpdate kind: \(kind, privacy: .public)")
        }
    }

    private func handlePlanUpdate(streamId: UUID, update: [String: JSONValue],
                                   continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let entries = update["entries"]?.arrayValue else { return }

        // Render a markdown checklist so the existing PlanCardView renders it.
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

        let planId = streams[streamId]?.planSyntheticId ?? "acp-plan"
        continuation.yield(.assistant(AssistantMessage(
            role: "assistant",
            content: [.toolUse(
                id: planId,
                name: "ExitPlanMode",
                input: ["plan": .string(markdown)]
            )]
        )))
        mutateStream(streamId) { $0.planEmitted = true }
    }

    private func handleToolCall(streamId: UUID, update: [String: JSONValue],
                                 continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let toolCallId = update["toolCallId"]?.stringValue else {
            logger.warning("[ACP] tool_call missing toolCallId")
            return
        }
        let title = update["title"]?.stringValue ?? update["kind"]?.stringValue ?? "tool"
        let rawInput = update["rawInput"]?.objectValue ?? [:]
        logger.info("[ACP] ⟵ tool_call id=\(toolCallId, privacy: .public) name=\(title, privacy: .public) inputKeys=[\(rawInput.keys.sorted().joined(separator: ","), privacy: .public)]")

        mutateStream(streamId) { $0.liveToolCalls.insert(toolCallId) }

        continuation.yield(.assistant(AssistantMessage(
            role: "assistant",
            content: [.toolUse(id: toolCallId, name: title, input: rawInput)]
        )))
    }

    private func handleToolCallUpdate(streamId: UUID, update: [String: JSONValue],
                                       continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let toolCallId = update["toolCallId"]?.stringValue else {
            logger.warning("[ACP] tool_call_update missing toolCallId")
            return
        }
        let status = update["status"]?.stringValue ?? "completed"
        logger.info("[ACP] ⟵ tool_call_update id=\(toolCallId, privacy: .public) status=\(status, privacy: .public)")

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

    private func handleAgentRequest(streamId: UUID, id: JSONValue, method: String, params: JSONValue) async {
        logger.info("[ACP] ⟵ agent-request \(method, privacy: .public) stream=\(streamId.uuidString.prefix(8), privacy: .public)")
        switch method {
        case "fs/read_text_file":
            await handleFsReadTextFile(streamId: streamId, id: id, params: params)
        case "fs/write_text_file":
            await handleFsWriteTextFile(streamId: streamId, id: id, params: params)
        case "session/request_permission":
            await handleSessionRequestPermission(streamId: streamId, id: id, params: params)
        default:
            logger.warning("[ACP] unsupported agent-request: \(method, privacy: .public)")
            sendError(streamId: streamId, id: id, code: -32601, message: "Method not supported: \(method)")
        }
    }

    private func handleFsReadTextFile(streamId: UUID, id: JSONValue, params: JSONValue) async {
        guard let path = params.objectValue?["path"]?.stringValue else {
            sendError(streamId: streamId, id: id, code: -32602, message: "Missing path")
            return
        }
        do {
            let line = params.objectValue?["line"]?.intValue
            let limit = params.objectValue?["limit"]?.intValue
            let content = try Self.readTextFile(path: path, line: line, limit: limit)
            sendResult(streamId: streamId, id: id, result: .object(["content": .string(content)]))
        } catch {
            sendError(streamId: streamId, id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleFsWriteTextFile(streamId: UUID, id: JSONValue, params: JSONValue) async {
        guard let path = params.objectValue?["path"]?.stringValue,
              let content = params.objectValue?["content"]?.stringValue else {
            sendError(streamId: streamId, id: id, code: -32602, message: "Missing path or content")
            return
        }
        do {
            try Self.writeTextFile(path: path, content: content)
            sendResult(streamId: streamId, id: id, result: .object([:]))
        } catch {
            sendError(streamId: streamId, id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleSessionRequestPermission(streamId: UUID, id: JSONValue, params: JSONValue) async {
        guard let entry = streams[streamId] else {
            logger.warning("[ACP] permission request arrived for closed stream")
            sendError(streamId: streamId, id: id, code: -32000, message: "Stream closed")
            return
        }
        let toolCall = params.objectValue?["toolCall"]?.objectValue ?? [:]
        let toolCallId = toolCall["toolCallId"]?.stringValue ?? UUID().uuidString
        let toolName = toolCall["title"]?.stringValue ?? toolCall["kind"]?.stringValue ?? "tool"
        let toolInput = toolCall["rawInput"]?.objectValue ?? [:]
        logger.info("[ACP] permission request tool=\(toolName, privacy: .public) id=\(toolCallId, privacy: .public)")

        guard let server = permissionServer else {
            // No permission server registered — auto-allow so the agent doesn't hang.
            let optionId = params.objectValue?["options"]?.arrayValue?
                .first(where: { $0.objectValue?["kind"]?.stringValue == "allow_once" })?
                .objectValue?["optionId"]?.stringValue ?? "allow"
            logger.warning("[ACP] no permission server — auto-allowing \(toolName, privacy: .public) via optionId=\(optionId, privacy: .public)")
            sendResult(streamId: streamId, id: id, result: .object([
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

        // Map RxCode decision to an ACP option from the options[] array, defaulting to allow_once / reject_once.
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

        sendResult(streamId: streamId, id: id, result: .object([
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
                    // SessionConfigSelectGroup — flatten its options.
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

    private func startStderrReader(streamId: UUID, stderr: FileHandle) {
        // Same rationale as `spawnStdoutReader`: avoid `FileHandle.bytes.lines`
        // and pump from `readabilityHandler` instead.
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
                    await self?.appendStderr(streamId: streamId, line: line)
                }
            }
        }
    }

    private func appendStderr(streamId: UUID, line: String) {
        mutateStream(streamId) { $0.stderr += line + "\n" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            logger.info("[ACP][stderr] \(trimmed, privacy: .public)")
        }
    }

    private func handleProcessExit(streamId: UUID) {
        guard let entry = streams[streamId] else { return }
        logger.info("[ACP] process exit pid=\(entry.process.processIdentifier) status=\(entry.process.terminationStatus) reason=\(String(describing: entry.process.terminationReason.rawValue), privacy: .public) pending=\(entry.pending.count) client=\(entry.spec.displayName, privacy: .public)")
        // If pending requests remain, fail them so the turn surfaces an error.
        for (_, cont) in entry.pending {
            cont.resume(throwing: ACPError.processExited(code: entry.process.terminationStatus))
        }
        mutateStream(streamId) { $0.pending.removeAll() }
        entry.continuation?.finish()
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
