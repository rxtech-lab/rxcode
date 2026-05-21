import Foundation
import RxCodeCore
import os

// MARK: - ClaudeCodeServer

/// Manages the Claude Code CLI process lifecycle and NDJSON streaming.
///
/// Spawns the `claude` binary with stream-json I/O, reads stdout as an
/// ``AsyncStream<StreamEvent>``, and writes user messages to stdin in NDJSON format.
actor ClaudeCodeServer {

    // MARK: - State

    /// PGIDs of concurrently running streaming CLI invocations — managed independently per streamId.
    ///
    /// The streaming `claude` is launched as a new session leader (via `posix_spawn` +
    /// `POSIX_SPAWN_SETSID`) so the leader pid == pgid == sid. This lets us reap the
    /// entire subagent subtree with a single `killpg` instead of chasing descendants
    /// individually, and also enables session-id filtering to find descendants whose
    /// parent chain was severed by reparenting to launchd.
    private var streamPGIDs: [UUID: pid_t] = [:]
    /// Accumulated set of every descendant pid ever observed for a stream. A background
    /// poller samples the live process table while the stream is running and unions the
    /// results here. This is the only way to catch descendants that call `setsid()`
    /// themselves (creating a new session that doesn't match our root sid) and then
    /// get reparented to launchd when an intermediate parent dies — by the time
    /// `finalize` runs, those processes are invisible to both the ppid walk and the
    /// session-id filter, but they were briefly findable while their parent was alive.
    private var trackedDescendants: [UUID: Set<pid_t>] = [:]
    /// Polling tasks that populate `trackedDescendants`. Cancelled in `removeProcess`.
    private var descendantTrackers: [UUID: Task<Void, Never>] = [:]
    /// Writable stdin handles per stream — used for sending follow-up messages (e.g., AskUserQuestion responses).
    /// Entry is removed when stdin is closed (after `result` event or on cancel).
    private var stdinHandles: [UUID: FileHandle] = [:]
    private var inactivityTimer: Task<Void, Never>?

    /// Per-stream stderr accumulator — used to deliver error messages when process exits without a response
    private var stderrBuffers: [UUID: String] = [:]

    private var streamSessionIds: [UUID: String] = [:]

    private let cliStore: CLISessionStore
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "ClaudeCodeServer"
    )

    init(cliStore: CLISessionStore) {
        self.cliStore = cliStore
    }

    // MARK: - Errors

    enum ClaudeError: LocalizedError {
        case binaryNotFound
        case versionCheckFailed(String)
        case processNotRunning
        case stdinUnavailable
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the claude CLI binary."
            case .versionCheckFailed(let detail):
                return "Version check failed: \(detail)"
            case .processNotRunning:
                return "No claude process is currently running."
            case .stdinUnavailable:
                return "stdin pipe is not available."
            case .spawnFailed(let detail):
                return "Failed to spawn claude process: \(detail)"
            }
        }
    }

    // MARK: - Shell PATH Resolution

    /// Cached PATH used for spawned subprocesses. Built once on first use.
    ///
    /// macOS GUI apps inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`)
    /// that excludes Homebrew, nvm, and npm-global locations. Without overriding
    /// PATH for spawned processes, the `claude` CLI fails with
    /// `env: node: No such file or directory` when its `node` shebang resolver
    /// cannot locate Node.
    private var cachedShellPath: String?

    /// Compose a PATH that lets the spawned `claude` CLI find `node` and
    /// related tools regardless of where the user installed them.
    ///
    /// Combines, in priority order:
    ///   1. The user's interactive login shell PATH (captures nvm/asdf/.zshrc init)
    ///   2. Well-known tool directories (Homebrew, npm-global, nvm latest)
    ///   3. The GUI process's existing PATH as a final fallback
    private func resolvedShellPath() async -> String {
        if let cached = cachedShellPath { return cached }

        var paths: [String] = []
        var seen = Set<String>()
        func add(_ entry: String) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            paths.append(trimmed)
        }

        if let shellPath = await readUserShellPath() {
            for component in shellPath.split(separator: ":") { add(String(component)) }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ] { add(dir) }

        if let nvmBin = latestNvmBinDirectory(home: home) { add(nvmBin) }

        if let existing = ProcessInfo.processInfo.environment["PATH"] {
            for component in existing.split(separator: ":") { add(String(component)) }
        }

        // Double-check after awaits: another reentrant caller may have populated it.
        if let cached = cachedShellPath { return cached }

        let combined = paths.joined(separator: ":")
        cachedShellPath = combined
        logger.info("Resolved shell PATH for subprocess (entries=\(paths.count))")
        return combined
    }

    /// Spawn the user's login shell once to read its `$PATH`.
    /// Uses `-ilc` so `.zshrc` (and the nvm/asdf init it typically sources) runs.
    private func readUserShellPath() async -> String? {
        do {
            let output = try await runShellCommand(
                "/bin/zsh",
                arguments: ["-ilc", "print -rn -- $PATH"],
                injectPath: false
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.warning("Failed to read user shell PATH: \(error.localizedDescription)")
            return nil
        }
    }

    /// Locate the bin directory of the most recent nvm-installed Node, if any.
    /// Defends against shell readout failure for nvm users.
    private func latestNvmBinDirectory(home: String) -> String? {
        let root = "\(home)/.nvm/versions/node"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries.sorted(by: >) {
            let bin = "\(root)/\(entry)/bin"
            if fm.isExecutableFile(atPath: "\(bin)/node") { return bin }
        }
        return nil
    }

    /// Build the full environment dictionary for spawned subprocesses,
    /// inheriting the GUI environment but with PATH replaced by ``resolvedShellPath()``.
    func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await resolvedShellPath()
        return env
    }

    // MARK: - Binary Discovery

    /// Well-known paths searched in order before falling back to the shell.
    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    /// Locate the `claude` binary on this machine.
    func findClaudeBinary() async -> String? {
        let fm = FileManager.default

        for path in Self.candidatePaths {
            // Resolve symlinks before checking
            let resolved = (path as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: path) {
                logger.info("Found claude binary at \(path, privacy: .public) -> \(resolved, privacy: .public)")
                return path
            }
        }

        // Shell fallback
        logger.info("Trying shell fallback to locate claude binary")
        do {
            let result = try await runShellCommand("/bin/zsh", arguments: ["-ilc", "whence -p claude"])
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                logger.info("Found claude binary via shell at \(path, privacy: .public)")
                return path
            }
        } catch {
            logger.warning("Shell fallback failed: \(error, privacy: .public)")
        }

        logger.error("claude binary not found")
        return nil
    }

    // MARK: - Local Command

    /// Run a local slash command (e.g. "/cost", "/usage") and return stdout.
    func runLocalCommand(_ command: String) async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let output = try await runShellCommand(binary, arguments: ["-p", command, "--output-format", "text"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run `/context` for a session and parse the used percentage.
    /// Returns nil if the session has no context info or parsing fails.
    func fetchContextPercentage(sessionId: String, cwd: String) async -> Double? {
        guard let binary = await findClaudeBinary() else { return nil }
        do {
            let output = try await runShellCommand(
                binary,
                arguments: ["-p", "/context", "--output-format", "text", "--resume", sessionId],
                cwd: cwd
            )
            // Parse "Tokens: 24.2k / 200k (12%)" pattern
            guard let match = output.range(of: #"\((\d+(?:\.\d+)?)%\)"#, options: .regularExpression) else {
                return nil
            }
            let captured = output[match].dropFirst(1).dropLast(2) // remove "(" and "%)"
            return Double(captured)
        } catch {
            logger.warning("Failed to fetch context: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Version Check

    /// Run `claude --version` and return the version string.
    func checkVersion() async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let output = try await runShellCommand(binary, arguments: ["--version"])
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\(Claude Code\)"#, with: "", options: .regularExpression)

        guard !version.isEmpty else {
            throw ClaudeError.versionCheckFailed("Empty version output")
        }

        logger.info("Claude CLI version: \(version, privacy: .public)")
        return version
    }

    // MARK: - Title Generation

    /// Generate a short 3–6 word title for a chat from the first user message.
    /// Uses a one-shot `claude -p` invocation with Haiku — runs outside of the streaming
    /// pipeline and does NOT hit the PermissionServer hook (no `--settings` passed).
    /// Returns nil on any failure; callers should keep the placeholder title in that case.
    func generateSessionTitle(firstUserMessage: String, model: String = "claude-haiku-4-5-20251001") async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let trimmedUser = String(firstUserMessage.prefix(500))
        let prompt = """
        Summarize the following user message as a 3-6 word chat title. \
        Reply with ONLY the title, no quotes, no markdown, no punctuation at the end.

        \(trimmedUser)
        """
        // Title generation is pure text — no tools needed. Strip MCP servers so a
        // user's broken tool schema (e.g. an MCP server returning invalid JSON schema)
        // can't blow up the title call with "API Error: 400 tools.NN.custom.input_schema".
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            let cleaned = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !cleaned.isEmpty else { return nil }
            // `claude -p` prints API/CLI failures to stdout (e.g. "API Error: 400 ...").
            // Don't promote those to the sidebar title — keep the placeholder instead.
            let lower = cleaned.lowercased()
            let errorPrefixes = ["api error", "error:", "execution error", "request failed", "claude error"]
            if errorPrefixes.contains(where: { lower.hasPrefix($0) }) {
                logger.warning("Title generation produced an error string; ignoring: \(cleaned.prefix(120))")
                return nil
            }
            return String(cleaned.prefix(80))
        } catch {
            logger.warning("Title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func generateResponseNotificationSummary(responseText: String, model: String = "claude-haiku-4-5-20251001") async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let trimmedResponse = String(responseText.prefix(4000))
        let prompt = """
        Summarize the following assistant response for a macOS notification. \
        Reply with one concise sentence under 180 characters. Mention the outcome and the most important result. \
        No markdown.

        \(trimmedResponse)
        """
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            let cleaned = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !cleaned.isEmpty else { return nil }
            let lower = cleaned.lowercased()
            let errorPrefixes = ["api error", "error:", "execution error", "request failed", "claude error"]
            if errorPrefixes.contains(where: { lower.hasPrefix($0) }) {
                logger.warning("Notification summary produced an error string; ignoring: \(cleaned.prefix(120))")
                return nil
            }
            return String(cleaned.prefix(180))
        } catch {
            logger.warning("Notification summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String,
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        let previous = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Update the stored summary for one project thread. Use the previous summary, latest user request, and final assistant response.
        Keep it factual and concise, 3-6 bullet points max. Include completed work, important decisions, files or areas touched, and unresolved follow-ups.
        Reply with only the updated summary.

        Previous summary:
        \((previous?.isEmpty == false) ? previous! : "None")

        Latest user request:
        \(String(userMessage.prefix(2000)))

        Final assistant response:
        \(String(finalResponse.prefix(4000)))
        """
        return await generatePlainSummary(prompt: prompt, model: model, limit: 1800)
    }

    func generateMemoryOperations(
        existingMemories: [(id: String, content: String)],
        userMessage: String,
        finalResponse: String,
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: existingMemories,
            userMessage: userMessage,
            finalResponse: finalResponse
        )
        return await generatePlainSummary(prompt: prompt, model: model, limit: 3000)
    }

    func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)],
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        guard !threadSummaries.isEmpty else { return nil }
        let prompt = OpenAISummarizationService.branchBriefingPrompt(threadSummaries: threadSummaries)
        return await generatePlainSummary(prompt: prompt, model: model, limit: 1800)
    }

    func generateCommitMessage(
        diff: String,
        fileSummary: String,
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        // Caller (AppState) has already applied a provider-aware budget; this
        // is just an upper bound to guard against accidental misuse.
        let trimmedDiff = String(diff.prefix(20_000))
        let prompt = """
        Write a Git commit message for the staged changes below in the Conventional Commits format.

        Format rules (MUST follow exactly):
        - First line: `<type>(<optional-scope>): <description>` — subject must be under 72 characters, lowercase imperative mood, no trailing period.
        - `<type>` MUST be one of: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
        - After the subject, an optional blank line followed by 1-3 short bullet points explaining the WHY (each starting with "- ").
        - Do NOT use markdown headings (no `#`, `##`).
        - Do NOT wrap the message in quotes or code fences.
        - Do NOT prefix with anything else; the very first characters must be the type.

        Example output:
        feat(git): add commit message generator

        - reuse summarization providers for on-device generation
        - support staged diff context

        Staged files:
        \(fileSummary)

        Staged diff:
        \(trimmedDiff)
        """
        return await generatePlainSummary(prompt: prompt, model: model, limit: 1000)
    }

    private func generatePlainSummary(prompt: String, model: String, limit: Int) async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            return cleanGeneratedSummary(output, limit: limit)
        } catch {
            logger.warning("Summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func cleanGeneratedSummary(_ raw: String, limit: Int) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "claude error"]
        guard !errorPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return String(cleaned.prefix(limit))
    }

    /// Write a one-off MCP config file (with no servers) used by the title-generation
    /// call so it doesn't inherit user-level MCP servers. Returns nil on I/O failure;
    /// caller falls back to the default config.
    private func writeEmptyMCPConfig() -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RxCode", isDirectory: true)
        let path = dir.appendingPathComponent("empty-mcp.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"mcpServers\":{}}".utf8).write(to: path, options: .atomic)
            return path.path
        } catch {
            logger.warning("Failed to write empty MCP config: \(error.localizedDescription)")
            return nil
        }
    }

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
                    log.error("[Stream] spawn failed: \(error.localizedDescription)")
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
    private func startDescendantTracker(streamId: UUID, root: pid_t) {
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

    private func mergeTrackedDescendants(streamId: UUID, pids: [pid_t]) {
        trackedDescendants[streamId, default: []].formUnion(pids)
    }

    /// Union of the live snapshot and every descendant ever seen for this stream.
    /// `kill(pid, 0)` filters out already-reaped pids so signals only target live ones.
    private func allKnownDescendants(streamId: UUID, root: pid_t, sid: pid_t) -> [pid_t] {
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
    private static func descendantPids(of root: pid_t, sid: pid_t) -> [pid_t] {
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

    // MARK: - Private Helpers

    /// Extra system-prompt text appended via `--append-system-prompt`. Tells the
    /// agent about the IDE-provided `rxcode-ide` MCP server, which lets it talk
    /// to agents in other RxCode projects/threads, introspect editor state, and
    /// recall/store durable cross-session memories.
    private static let ideToolsSystemPrompt = """
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

    RxCode also persists durable memories — stable user preferences, project \
    facts, and decisions — across sessions. Use these tools to recall and \
    store them:

    - `mcp__rxcode-ide__ide__memory_search` — before starting a task, search \
    for saved preferences, facts, or decisions relevant to it instead of \
    asking the user to repeat themselves.
    - `mcp__rxcode-ide__ide__memory_add` — when the user states a stable \
    preference, project fact, or decision ("remember…", "from now on…", \
    "always…"), save it. Set `kind` (`preference`/`fact`/`decision`) and \
    `scope` (`global` for cross-project, `project` for repo-specific).
    - `mcp__rxcode-ide__ide__memory_update` — when saved information changes, \
    update the existing entry by `id` rather than adding a duplicate.
    - `mcp__rxcode-ide__ide__memory_delete` — remove a memory by `id` when it \
    is no longer valid.

    Only store stable, reusable information in memory — not transient task \
    details.
    """

    /// Build arguments array for the CLI invocation.
    ///
    /// The user prompt is NOT a CLI argument — it is written to stdin as a JSON
    /// user message (see `spawnProcess`) because we run the CLI with
    /// `--input-format stream-json`.
    private func buildArguments(
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

    /// Launch the streaming `claude` CLI in its own process group via `posix_spawn`.
    ///
    /// Foundation's `Process` does not expose `posix_spawnattr_t`, so the streaming
    /// invocation goes through the raw POSIX API. The new group means the leader's
    /// pid is also its pgid — `killpg(pid, ...)` reaches every subagent the CLI
    /// spawns via the Task tool.
    private func spawnProcess(
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
    private func handleProcessExit(streamId: UUID, cwd: String) async {
        finalize(streamId: streamId)
        removeProcess(streamId: streamId)
        if let sid = consumeSessionId(streamId: streamId) {
            await cliStore.exposeToPicker(sid: sid, cwd: cwd)
        }
    }

    /// Spawn `executable` with `arguments` in its own process group.
    /// Returns the child pid (== pgid since `POSIX_SPAWN_SETPGROUP` with group 0
    /// makes the child its own group leader).
    private static func spawnInNewProcessGroup(
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
    private static func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        handle.write(data)
        handle.write(Data([0x0A])) // newline
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
    private func removeProcess(streamId: UUID) {
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

    private func clearTrackedDescendants(streamId: UUID) {
        trackedDescendants.removeValue(forKey: streamId)
    }

    private func recordSessionId(streamId: UUID, sessionId: String) {
        streamSessionIds[streamId] = sessionId
    }

    private func consumeSessionId(streamId: UUID) -> String? {
        streamSessionIds.removeValue(forKey: streamId)
    }

    /// Read stderr asynchronously, log each line, and buffer for error reporting.
    private nonisolated func readStderr(_ pipe: Pipe, streamId: UUID) {
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
    private func appendStderr(_ text: String, for streamId: UUID) {
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

    /// Run a simple command and return its stdout as a String.
    /// Uses async termination handling to avoid blocking the actor's cooperative thread.
    ///
    /// `injectPath` controls whether the spawned process receives the resolved
    /// shell PATH. Set to `false` when this method is itself used to *resolve*
    /// the shell PATH, to break the chicken-and-egg loop.
    private func runShellCommand(
        _ command: String,
        arguments: [String] = [],
        cwd: String? = nil,
        injectPath: Bool = true
    ) async throws -> String {
        let proc = Process()
        let pipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.environment = injectPath
            ? await resolvedEnvironment()
            : ProcessInfo.processInfo.environment
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        try proc.run()

        // Wait for process exit asynchronously instead of blocking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Cleanup

    /// Tear down any resources held by the service. Called on app termination
    /// so spawned `claude` CLIs (and any subagent or MCP server children they
    /// hold open) don't outlive the host app and linger in Activity Monitor.
    func cleanup() {
        inactivityTimer?.cancel()
        inactivityTimer = nil

        // Cancel pollers so they don't race with the teardown.
        for (_, task) in descendantTrackers { task.cancel() }
        descendantTrackers.removeAll()

        // Snapshot every descendant tree before signaling so escaped subagents
        // (MCP servers detached via setsid) still get the SIGKILL pass.
        // Capture sid per stream while roots are alive — see finalize() for rationale.
        let streamSnapshots: [(UUID, pid_t, pid_t)] = streamPGIDs.map { ($0.key, $0.value, getsid($0.value)) }
        var allEscapees: [pid_t] = []
        for (streamId, pgid, sid) in streamSnapshots {
            allEscapees.append(contentsOf: allKnownDescendants(streamId: streamId, root: pgid, sid: sid))
        }

        for (_, pgid, _) in streamSnapshots {
            killpg(pgid, SIGTERM)
        }
        for pid in allEscapees { kill(pid, SIGTERM) }

        // Synchronous SIGKILL escalation — the host process is exiting, so a
        // detached Task wouldn't have time to fire. Re-snapshot to catch any
        // descendants that emerged or were reparented between SIGTERM and now.
        usleep(200_000)
        var finalEscapees: [pid_t] = []
        for (streamId, pgid, sid) in streamSnapshots {
            finalEscapees.append(contentsOf: allKnownDescendants(streamId: streamId, root: pgid, sid: sid))
        }
        for (_, pgid, _) in streamSnapshots {
            killpg(pgid, SIGKILL)
        }
        for pid in finalEscapees { kill(pid, SIGKILL) }
        trackedDescendants.removeAll()

        streamPGIDs.removeAll()
        for (_, handle) in stdinHandles {
            try? handle.close()
        }
        stdinHandles.removeAll()
    }
}

typealias ClaudeService = ClaudeCodeServer

// MARK: - AgentBackend Conformance

extension ClaudeCodeServer: AgentBackend {
    nonisolated var provider: AgentProvider { .claudeCode }
    nonisolated var staticCapabilities: CapabilitySet { AgentProvider.claudeCode.staticCapabilities }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        send(
            streamId: request.streamId,
            prompt: request.prompt,
            cwd: request.cwd,
            sessionId: request.sessionId,
            model: request.model,
            effort: request.effort,
            hookSettingsPath: request.hookSettingsPath,
            mcpConfigPath: request.mcpClaudeConfigPath,
            extraSystemPrompt: request.extraSystemPrompt,
            permissionMode: request.permissionMode
        )
    }
}
