import Foundation
import RxCodeCore
import os

// MARK: - Process Spawn & Streaming

extension ClaudeCodeServer {

    // MARK: - Send (spawn + stream)

    /// Spawn the CLI and return a stream of parsed events.
    ///
    /// Architecture: a single `Task.detached` reads stdout line-by-line,
    /// decodes NDJSON, and yields `StreamEvent`s. No intermediate streams,
    /// no shared-actor scheduling issues.
    ///
    /// Multiple concurrent streams are managed independently via `streamId`.
    func send(
        streamId: UUID,
        prompt: String,
        cwd: String,
        sessionId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        hookSettingsPath: String? = nil,
        mcpConfigPath: String? = nil,
        extraSystemPrompt: String? = nil,
        permissionMode: PermissionMode = .default
    ) -> AsyncStream<StreamEvent> {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let log = self.logger
        let currentStreamId = streamId

        readStderr(stderr, streamId: currentStreamId)

        return AsyncStream<StreamEvent> { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                // Spawn process (hops to ClaudeService actor for state)
                do {
                    try await self.spawnProcess(
                        streamId: streamId,
                        prompt: prompt,
                        cwd: cwd,
                        sessionId: sessionId,
                        model: model,
                        effort: effort,
                        hookSettingsPath: hookSettingsPath,
                        mcpConfigPath: mcpConfigPath,
                        extraSystemPrompt: extraSystemPrompt,
                        permissionMode: permissionMode,
                        stdinPipe: stdin,
                        stdoutPipe: stdout,
                        stderrPipe: stderr,
                        onProcessExit: {
                            // Wait 2 seconds after process exit to flush remaining buffers
                            // before finishing the stream. continuation.finish() is thread-safe and
                            // idempotent, so duplicate calls on normal exit are safe.
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                                continuation.finish()
                            }
                        }
                    )
                } catch {
                    // Distinguish "could not launch the CLI" (binary missing,
                    // posix_spawn failed) from "launched but stdin write to
                    // send the user prompt failed" (CLI exited immediately,
                    // broken pipe). Both end the stream, but the latter is a
                    // legitimate runtime hang surfaced through `.result` so
                    // the UI shows a real error bubble instead of a generic
                    // "No response received".
                    log.error("[Stream] spawn failed: \(error.localizedDescription)")
                    let description: String
                    if case ClaudeError.spawnFailed(let msg) = error {
                        description = "Failed to start Claude CLI: \(msg)"
                    } else if case ClaudeError.binaryNotFound = error {
                        description = "Claude CLI binary not found."
                    } else {
                        description = "Failed to send to Claude CLI: \(error.localizedDescription)"
                    }
                    continuation.yield(.user(UserMessage(
                        toolUseId: nil,
                        content: description,
                        isError: true
                    )))
                    continuation.yield(.result(ResultEvent(
                        durationMs: nil, totalCostUsd: nil,
                        sessionId: sessionId ?? streamId.uuidString,
                        isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                    )))
                    continuation.finish()
                    return
                }

                // Read stdout line-by-line — ends naturally at EOF
                var parsedCount = 0
                var failedCount = 0
                let decoder = JSONDecoder()
                log.info("[Stream] starting stdout read loop")

                var rawLineCount = 0
                var capturedSessionId: String?
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8) else { continue }

                        rawLineCount += 1
                        // Diagnostic logging of raw NDJSON — full content for first 30 lines, then type field only
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let type = (json["type"] as? String) ?? "?"
                            if rawLineCount <= 30 {
                                log.info("[Stream:RAW] #\(rawLineCount) type=\(type) line=\(line.prefix(600))")
                            } else if type == "stream_event" || rawLineCount % 50 == 0 {
                                log.info("[Stream:RAW] #\(rawLineCount) type=\(type)")
                            }
                            if capturedSessionId == nil,
                               let sid = (json["session_id"] as? String) ?? (json["sessionId"] as? String) {
                                capturedSessionId = sid
                                Task { await self.recordSessionId(streamId: streamId, sessionId: sid) }
                            }
                        } else if rawLineCount <= 30 {
                            log.info("[Stream:RAW] #\(rawLineCount) non-JSON line=\(line.prefix(600))")
                        }

                        do {
                            let event = try decoder.decode(StreamEvent.self, from: data)
                            parsedCount += 1
                            continuation.yield(event)
                        } catch {
                            failedCount += 1
                            // Yield raw string so partial events still reach the UI
                            continuation.yield(.unknown(line))
                            if failedCount <= 5 {
                                log.warning("[Stream] parse failed #\(failedCount): \(line.prefix(200))")
                            }
                        }
                    }
                } catch {
                    log.warning("[Stream] stdout read error: \(error.localizedDescription)")
                }

                log.info("[Stream] stdout ended (parsed=\(parsedCount), failed=\(failedCount))")
                continuation.finish()
            }

            continuation.onTermination = { reason in
                log.info("[Stream] terminated (reason=\(String(describing: reason)))")
                task.cancel()
                // Close the pipe after the stream ends to unblock the bytes.lines read.
                // onTermination is called after finish(), so there is no data loss.
                stdout.fileHandleForReading.closeFile()
            }
        }
    }

    // MARK: - Descendant tracker

    /// Start a background poller that periodically snapshots every descendant of `root`
    /// and merges them into `trackedDescendants[streamId]`. The accumulated set is the
    /// safety net for descendants that briefly exist as findable children of `root`
    /// before detaching themselves (via `setsid`/`setpgid`) and being reparented away.
    ///
    /// Cancelled in `removeProcess` when the stream ends.
    func startDescendantTracker(streamId: UUID, root: pid_t) {
        // Capture sid once at startup — getsid() on a live root returns the session id,
        // which equals `root` itself since we spawned with POSIX_SPAWN_SETSID.
        let sid = getsid(root)
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let pids = Self.descendantPids(of: root, sid: sid)
                if !pids.isEmpty {
                    await self?.mergeTrackedDescendants(streamId: streamId, pids: pids)
                }
                // 500ms is a balance: short enough to catch transient ppid links before
                // an intermediate parent dies and reparenting hides the child, while not
                // burning measurable CPU on the `ps` invocation (~5ms per snapshot).
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        descendantTrackers[streamId] = task
    }

    func mergeTrackedDescendants(streamId: UUID, pids: [pid_t]) {
        trackedDescendants[streamId, default: []].formUnion(pids)
    }

    /// Union of the live snapshot and every descendant ever seen for this stream.
    /// `kill(pid, 0)` filters out already-reaped pids so signals only target live ones.
    func allKnownDescendants(streamId: UUID, root: pid_t, sid: pid_t) -> [pid_t] {
        var union = trackedDescendants[streamId] ?? []
        union.formUnion(Self.descendantPids(of: root, sid: sid))
        return union.filter { kill($0, 0) == 0 }
    }

    // MARK: - Cancel / Finalize

    /// User-initiated stop. Send SIGINT to the entire process group so subagent
    /// children die alongside the parent. Escalate to SIGKILL after 5 seconds.
    func cancel(streamId: UUID) {
        guard let pgid = streamPGIDs[streamId] else { return }
        // Capture sid while the root is still alive — getsid(pid) returns -1 once
        // the process is fully reaped, but the value is needed for the SIGKILL re-snapshot.
        let sid = getsid(pgid)
        let escapees = allKnownDescendants(streamId: streamId, root: pgid, sid: sid)

        logger.info("Sending SIGINT to claude pgid \(pgid) escapees=\(escapees) (stream=\(streamId))")
        killpg(pgid, SIGINT)
        for pid in escapees { kill(pid, SIGINT) }

        let log = logger
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // Re-snapshot before SIGKILL — picks up anything that emerged in the 5s window.
            let finalEscapees = await self?.allKnownDescendants(streamId: streamId, root: pgid, sid: sid) ?? []
            // killpg/kill on a fully-dead target returns ESRCH — harmless. Send unconditionally
            // to cover any subagent that ignored SIGINT or escaped the process group.
            killpg(pgid, SIGKILL)
            for pid in finalEscapees { kill(pid, SIGKILL) }
            log.debug("Cancel SIGKILL pgid=\(pgid) escapees=\(finalEscapees)")
        }
    }

    /// Thread-finished sweep. Called after the `result` event (and from the exit
    /// handler) to guarantee no subagent process outlives the parent CLI.
    ///
    /// MCP servers and Node children spawned `detached: true` may escape the
    /// parent's process group (via `setsid`/`setpgid`), so `killpg` alone is not
    /// enough. Snapshot the descendant tree before signaling and SIGKILL each
    /// escapee individually as the safety net — running in a detached Task so
    /// actor contention can't delay the escalation.
    func finalize(streamId: UUID) {
        // Claim the entry atomically so a second concurrent caller (e.g. AppState's
        // result-driven finalize racing with the waitpid-driven handleProcessExit)
        // becomes a no-op instead of re-signaling an already-reaped pgid.
        guard let pgid = streamPGIDs.removeValue(forKey: streamId) else { return }
        // Capture sid while the root is still alive — see cancel() for rationale.
        let sid = getsid(pgid)
        let escapees = allKnownDescendants(streamId: streamId, root: pgid, sid: sid)

        logger.info("Finalizing stream — pgid=\(pgid) sid=\(sid) escapees=\(escapees) stream=\(streamId)")
        killpg(pgid, SIGTERM)
        for pid in escapees { kill(pid, SIGTERM) }

        let log = logger
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Re-snapshot before SIGKILL. By this time the root may have already
            // exited; the accumulated `trackedDescendants` set is what catches
            // session-escaped, reparented processes that no live ps query can find.
            let finalEscapees = await self?.allKnownDescendants(streamId: streamId, root: pgid, sid: sid) ?? []
            killpg(pgid, SIGKILL)
            for pid in finalEscapees { kill(pid, SIGKILL) }
            log.debug("Finalize SIGKILL pgid=\(pgid) escapees=\(finalEscapees)")
        }
    }

    /// Find every descendant pid of `root` (not including `root`). Combines two
    /// strategies for maximum coverage:
    ///
    /// 1. **Parent walk** — BFS via `ps -Ao pid,ppid`. Catches everything reachable
    ///    through ppid links from `root`. Works for live, non-reparented trees but
    ///    breaks once an intermediate parent dies and its children are reparented
    ///    to launchd (ppid=1).
    /// 2. **Session match** — for each running pid, compare `getsid(pid)` to the
    ///    passed-in `sid`. Catches descendants that broke out of the pgid (called
    ///    `setpgid`) and whose ppid chain was severed by reparenting, as long as
    ///    they did not call `setsid` themselves. Relies on the root having been
    ///    spawned with `POSIX_SPAWN_SETSID` so that `sid == root`.
    ///
    /// Pass `sid: 0` to skip the session match (e.g., if `getsid(root)` already
    /// returned an error). Callers should capture `sid` while the root is alive,
    /// since `getsid()` on a reaped pid returns -1.
    static func descendantPids(of root: pid_t, sid: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid,ppid"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        var allPids: [pid_t] = []
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            childrenByParent[ppid, default: []].append(pid)
            allPids.append(pid)
        }

        var result = Set<pid_t>()

        // (1) BFS via ppid links — works while parent chain is intact.
        var queue: [pid_t] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard let children = childrenByParent[next] else { continue }
            for child in children where child != root {
                if result.insert(child).inserted {
                    queue.append(child)
                }
            }
        }

        // (2) Session-id match — survives reparenting; misses processes that
        //     called setsid themselves (rare for CLI subagents).
        if sid > 0 {
            for pid in allPids where pid != root {
                if getsid(pid) == sid {
                    result.insert(pid)
                }
            }
        }

        return Array(result)
    }

    // MARK: - Argument Building

    /// Extra system-prompt text appended via `--append-system-prompt`. Tells the
    /// agent about the IDE-provided `rxcode-ide` MCP server, which lets it talk
    /// to agents in other RxCode projects/threads, introspect editor state, and
    /// recall/store durable cross-session memories.
    static let ideToolsSystemPrompt = """
    # RxCode IDE tools

    You are running inside RxCode, a desktop IDE that hosts multiple projects, \
    each with its own chat threads and agents. RxCode injects a local MCP \
    server named `rxcode-ide`; its tools are exposed to you with the \
    `mcp__rxcode-ide__` prefix. Use them to coordinate with other agents \
    (multi-agent talk) and to read editor state:

    - `mcp__rxcode-ide__ide__get_projects` — list every project registered in \
    RxCode, so you can discover sibling projects to read or message.
    - `mcp__rxcode-ide__ide__get_threads` — list or natural-language search \
    chat threads across projects (returns AI summaries, and ranked snippets \
    when a query is given).
    - `mcp__rxcode-ide__ide__get_thread_messages` — fetch the message history \
    of a specific thread by id.
    - `mcp__rxcode-ide__ide__send_to_thread` — talk to another project's agent: \
    send a prompt to an existing thread (`thread_id`) or start a new thread in \
    a project (`project_id`). This triggers a real agent run that may consume \
    tokens; it returns the other agent's reply.
    - `mcp__rxcode-ide__ide__get_running_jobs` / `ide__get_job_output` — \
    inspect run-profile jobs (dev servers, scripts) executing in the IDE.
    - `mcp__rxcode-ide__ide__get_usage` — current rate-limit / token usage.

    Reach for these when a task spans projects — e.g. checking what another \
    project already did, or delegating a subtask to its agent — rather than \
    guessing. Prefer reading threads first; only use `ide__send_to_thread` when \
    you actually need another agent to act, since it costs tokens.

    RxCode also persists durable memories across sessions. Use these tools to \
    recall saved preferences and to store only explicit user-requested memory:

    - `mcp__rxcode-ide__ide__memory_search` — before starting a task, search \
    for saved preferences, facts, or decisions relevant to it instead of \
    asking the user to repeat themselves.
    - `mcp__rxcode-ide__ide__memory_add` — only when the user explicitly asks \
    you to remember something, states a stable preference, or gives a \
    recurring instruction for future/next-time agent runs ("remember…", \
    "from now on…", "always…", "next time…"). Set `kind` \
    (`preference`/`fact`/`decision`) and `scope` (`global` for cross-project, \
    `project` for repo-specific).
    - `mcp__rxcode-ide__ide__memory_update` — when saved information changes, \
    update the existing entry by `id` rather than adding a duplicate.
    - `mcp__rxcode-ide__ide__memory_delete` — remove a memory by `id` when it \
    is no longer valid.

    Do not store completed work, build results, files changed, available \
    tools, routine requests, or other transient task details.
    """

    /// Build arguments array for the CLI invocation.
    ///
    /// The user prompt is NOT a CLI argument — it is written to stdin as a JSON
    /// user message (see `spawnProcess`) because we run the CLI with
    /// `--input-format stream-json`.
    func buildArguments(
        sessionId: String?,
        model: String?,
        effort: String?,
        hookSettingsPath: String?,
        mcpConfigPath: String?,
        extraSystemPrompt: String?,
        permissionMode: PermissionMode
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]

        if permissionMode != .default {
            args += ["--permission-mode", permissionMode.rawValue]
        }

        if !permissionMode.skipsHookPipeline {
            // Pre-approve safe tools that don't need to go through hooks via --allowedTools.
            // This eliminates HTTP round-trips from internal agent mechanics like Read/Grep/Task,
            // since no approval UI is shown for these.
            let safeTools = [
                "Read", "Glob", "Grep", "LS",
                "TodoRead", "TodoWrite",
                "Agent", "Task", "TaskOutput",
                "Notebook", "NotebookEdit",
                "WebSearch", "WebFetch",
            ]
            args += ["--allowedTools", safeTools.joined(separator: ",")]
        }

        if let hookSettingsPath {
            args += ["--settings", hookSettingsPath]
        }

        if let mcpConfigPath {
            args += ["--strict-mcp-config", "--mcp-config", mcpConfigPath]
        }

        // Assemble the system-prompt additions for this turn into a single
        // `--append-system-prompt` value (the CLI honours one occurrence):
        //  - IDE tools blurb, when the `rxcode-ide` MCP server is wired in.
        //  - Caller-supplied context, e.g. the current branch briefing.
        var systemPromptSections: [String] = []
        if mcpConfigPath != nil {
            systemPromptSections.append(Self.ideToolsSystemPrompt)
        }
        if let extraSystemPrompt, !extraSystemPrompt.isEmpty {
            systemPromptSections.append(extraSystemPrompt)
        }
        if !systemPromptSections.isEmpty {
            args += ["--append-system-prompt", systemPromptSections.joined(separator: "\n\n")]
        }

        if let sessionId {
            args += ["--resume", sessionId]
        }

        if let model {
            args += ["--model", model]
        }

        if let effort {
            args += ["--effort", effort]
        }

        // With `--input-format stream-json`, the prompt is sent via stdin as a JSON
        // user message (see spawnProcess) rather than as a CLI argument.
        return args
    }

    // MARK: - Spawn

    /// Launch the streaming `claude` CLI in its own process group via `posix_spawn`.
    ///
    /// Foundation's `Process` does not expose `posix_spawnattr_t`, so the streaming
    /// invocation goes through the raw POSIX API. The new group means the leader's
    /// pid is also its pgid — `killpg(pid, ...)` reaches every subagent the CLI
    /// spawns via the Task tool.
    func spawnProcess(
        streamId: UUID,
        prompt: String,
        cwd: String,
        sessionId: String?,
        model: String?,
        effort: String? = nil,
        hookSettingsPath: String?,
        mcpConfigPath: String?,
        extraSystemPrompt: String? = nil,
        permissionMode: PermissionMode = .default,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        onProcessExit: (@Sendable () -> Void)? = nil
    ) async throws {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let arguments = buildArguments(
            sessionId: sessionId,
            model: model,
            effort: effort,
            hookSettingsPath: hookSettingsPath,
            mcpConfigPath: mcpConfigPath,
            extraSystemPrompt: extraSystemPrompt,
            permissionMode: permissionMode
        )
        let environment = await resolvedEnvironment()

        let stdinReadFD = stdinPipe.fileHandleForReading.fileDescriptor
        let stdoutWriteFD = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrWriteFD = stderrPipe.fileHandleForWriting.fileDescriptor

        let pid: pid_t
        do {
            pid = try Self.spawnInNewProcessGroup(
                executable: binary,
                arguments: arguments,
                environment: environment,
                cwd: cwd,
                stdinReadFD: stdinReadFD,
                stdoutWriteFD: stdoutWriteFD,
                stderrWriteFD: stderrWriteFD
            )
        } catch {
            logger.error("Failed to spawn claude: \(error, privacy: .public)")
            throw ClaudeError.spawnFailed(error.localizedDescription)
        }

        // Parent must release the child-owned pipe ends so EOF propagates correctly.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Keep stdin open for stream-json input protocol. closed in `closeStdin(streamId:)`
        // after the `result` event so the CLI can flush remaining output and exit.
        let stdinHandle = stdinPipe.fileHandleForWriting
        self.streamPGIDs[streamId] = pid
        self.stdinHandles[streamId] = stdinHandle
        self.startDescendantTracker(streamId: streamId, root: pid)

        // Send the initial user prompt as an NDJSON user message.
        let userMessage: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt]
                ]
            ]
        ]
        try Self.writeJSONLine(userMessage, to: stdinHandle)

        logger.info(
            "Spawned claude process pid=\(pid) pgid=\(pid) cwd=\(cwd, privacy: .public) stream=\(streamId)"
        )

        // Wait for the parent CLI to exit on a background thread, then sweep
        // the process group to reap any subagent children that outlived it.
        let log = logger
        let cwdCopy = cwd
        Task.detached { [weak self] in
            var status: Int32 = 0
            var rc: pid_t = 0
            repeat {
                rc = waitpid(pid, &status, 0)
            } while rc < 0 && errno == EINTR

            log.info(
                "claude process exited — pid=\(pid) raw_status=\(status) stream=\(streamId)"
            )

            await self?.handleProcessExit(streamId: streamId, cwd: cwdCopy)
            onProcessExit?()
        }
    }

    /// Run after the parent CLI's `waitpid` returns. Sweep any surviving subagents
    /// in the same process group, then drop bookkeeping for the stream.
    func handleProcessExit(streamId: UUID, cwd: String) async {
        finalize(streamId: streamId)
        removeProcess(streamId: streamId)
        if let sid = consumeSessionId(streamId: streamId) {
            await cliStore.exposeToPicker(sid: sid, cwd: cwd)
        }
    }

    /// Spawn `executable` with `arguments` in its own process group.
    /// Returns the child pid (== pgid since `POSIX_SPAWN_SETPGROUP` with group 0
    /// makes the child its own group leader).
    static func spawnInNewProcessGroup(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        stdinReadFD: Int32,
        stdoutWriteFD: Int32,
        stderrWriteFD: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ClaudeError.spawnFailed("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        _ = posix_spawn_file_actions_adddup2(&fileActions, stdinReadFD, 0)
        _ = posix_spawn_file_actions_adddup2(&fileActions, stdoutWriteFD, 1)
        _ = posix_spawn_file_actions_adddup2(&fileActions, stderrWriteFD, 2)

        let chdirRC = cwd.withCString { cwdPtr in
            posix_spawn_file_actions_addchdir_np(&fileActions, cwdPtr)
        }
        if chdirRC != 0 {
            throw ClaudeError.spawnFailed("posix_spawn_file_actions_addchdir_np failed: \(chdirRC)")
        }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw ClaudeError.spawnFailed("posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attr) }

        // SETSID makes the child a new session leader (sid == pid == pgid). Session id
        // is preserved across reparenting, so we can locate descendants via getsid()
        // even after an intermediate parent has died and orphans were reparented to
        // launchd. Pure SETPGROUP would not survive reparenting on its own.
        _ = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv { if let p = p { free(p) } } }

        let envEntries = environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envEntries.map { strdup($0) }
        envp.append(nil)
        defer { for p in envp { if let p = p { free(p) } } }

        var pid: pid_t = 0
        let rc = executable.withCString { execPath in
            posix_spawn(&pid, execPath, &fileActions, &attr, argv, envp)
        }
        if rc != 0 {
            let msg = String(cString: strerror(rc))
            throw ClaudeError.spawnFailed("posix_spawn failed: \(msg) (\(rc))")
        }
        return pid
    }

    // MARK: - Stdin Writer

    /// Serialize a dictionary to JSON and write to stdin as one NDJSON line.
    /// Non-isolated to allow use from `spawnProcess` after `try proc.run()`.
    ///
    /// Uses the Swift-throwing `write(contentsOf:)` rather than the legacy
    /// `write(_:)` — the latter raises an Objective-C `NSFileHandleOperationException`
    /// on broken-pipe (e.g. CLI already died before we sent the user message),
    /// which Swift cannot catch and would terminate the app instead of letting
    /// the caller surface a real error to the user.
    static func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A])) // newline
    }

    /// Close stdin for an active stream. Call this after receiving the `result` event
    /// so the CLI process exits cleanly once it has flushed all remaining output.
    func closeStdin(streamId: UUID) {
        guard let handle = stdinHandles.removeValue(forKey: streamId) else { return }
        do {
            try handle.close()
            logger.info("Closed stdin for stream=\(streamId)")
        } catch {
            logger.warning("closeStdin error for stream=\(streamId): \(error.localizedDescription)")
        }
    }

    /// Remove a stream's bookkeeping from within actor isolation, called from
    /// the waitpid-driven exit handler.
    func removeProcess(streamId: UUID) {
        streamPGIDs.removeValue(forKey: streamId)
        descendantTrackers.removeValue(forKey: streamId)?.cancel()
        // Retain `trackedDescendants[streamId]` long enough for the SIGKILL re-snapshot
        // in cancel/finalize (those run in detached tasks after this method). Clear it
        // after a short delay so the actor doesn't accumulate stale entries.
        let clearKey = streamId
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await self?.clearTrackedDescendants(streamId: clearKey)
        }
        // If stdin is still open (e.g. abnormal exit before `result`), release the handle.
        if let handle = stdinHandles.removeValue(forKey: streamId) {
            try? handle.close()
        }
    }

    func clearTrackedDescendants(streamId: UUID) {
        trackedDescendants.removeValue(forKey: streamId)
    }

    func recordSessionId(streamId: UUID, sessionId: String) {
        streamSessionIds[streamId] = sessionId
    }

    func consumeSessionId(streamId: UUID) -> String? {
        streamSessionIds.removeValue(forKey: streamId)
    }

    /// Read stderr asynchronously, log each line, and buffer for error reporting.
    nonisolated func readStderr(_ pipe: Pipe, streamId: UUID) {
        let log = logger
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                pipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    log.debug("[stderr] \(line, privacy: .public)")
                }
                Task { await self?.appendStderr(text, for: streamId) }
            }
        }
    }

    /// Append text to the stderr buffer
    func appendStderr(_ text: String, for streamId: UUID) {
        stderrBuffers[streamId, default: ""] += text
    }

    /// Consume and return the stderr buffer for a given stream
    func consumeStderr(for streamId: UUID) -> String? {
        guard let buffer = stderrBuffers.removeValue(forKey: streamId),
              !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
