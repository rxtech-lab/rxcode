import Foundation
import RxCodeCore
import os

// MARK: - ClaudeCodeServer

/// Manages the Claude Code CLI process lifecycle and NDJSON streaming.
///
/// Spawns the `claude` binary with stream-json I/O, reads stdout as an
/// ``AsyncStream<StreamEvent>``, and writes user messages to stdin in NDJSON format.
///
/// The implementation is split across extensions in sibling files:
///   - `ClaudeService+Discovery.swift`  — PATH/binary discovery, version, shell runner
///   - `ClaudeService+Summaries.swift`  — title/commit/thread summary generation
///   - `ClaudeService+Process.swift`    — spawn, streaming, descendant tracking, cancel
actor ClaudeCodeServer {

    // MARK: - State

    /// PGIDs of concurrently running streaming CLI invocations — managed independently per streamId.
    ///
    /// The streaming `claude` is launched as a new session leader (via `posix_spawn` +
    /// `POSIX_SPAWN_SETSID`) so the leader pid == pgid == sid. This lets us reap the
    /// entire subagent subtree with a single `killpg` instead of chasing descendants
    /// individually, and also enables session-id filtering to find descendants whose
    /// parent chain was severed by reparenting to launchd.
    var streamPGIDs: [UUID: pid_t] = [:]
    /// Accumulated set of every descendant pid ever observed for a stream. A background
    /// poller samples the live process table while the stream is running and unions the
    /// results here. This is the only way to catch descendants that call `setsid()`
    /// themselves (creating a new session that doesn't match our root sid) and then
    /// get reparented to launchd when an intermediate parent dies — by the time
    /// `finalize` runs, those processes are invisible to both the ppid walk and the
    /// session-id filter, but they were briefly findable while their parent was alive.
    var trackedDescendants: [UUID: Set<pid_t>] = [:]
    /// Polling tasks that populate `trackedDescendants`. Cancelled in `removeProcess`.
    var descendantTrackers: [UUID: Task<Void, Never>] = [:]
    /// Writable stdin handles per stream — used for sending follow-up messages (e.g., AskUserQuestion responses).
    /// Entry is removed when stdin is closed (after `result` event or on cancel).
    var stdinHandles: [UUID: FileHandle] = [:]
    var inactivityTimer: Task<Void, Never>?

    /// Per-stream stderr accumulator — used to deliver error messages when process exits without a response
    var stderrBuffers: [UUID: String] = [:]

    var streamSessionIds: [UUID: String] = [:]

    let cliStore: CLISessionStore
    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "ClaudeCodeServer"
    )

    /// Cached PATH used for spawned subprocesses. Built once on first use.
    ///
    /// macOS GUI apps inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`)
    /// that excludes Homebrew, nvm, and npm-global locations. Without overriding
    /// PATH for spawned processes, the `claude` CLI fails with
    /// `env: node: No such file or directory` when its `node` shebang resolver
    /// cannot locate Node.
    var cachedShellPath: String?

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
