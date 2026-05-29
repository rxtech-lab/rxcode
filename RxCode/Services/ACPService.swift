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
//
// This file holds the actor declaration, stored state, and pool lifecycle.
// Turn running, process spawning, JSON-RPC framing, and helpers live in the
// `ACPService+*.swift` extensions.

actor ACPService {

    let logger = Logger(subsystem: "com.claudework", category: "ACPService")

    /// Per-pool entry. Persistent fields outlive a single turn; per-turn
    /// fields are reset before each `session/prompt`.
    struct SessionEntry {
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
        var stdoutLineCount: Int = 0

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

    var sessions: [String: SessionEntry] = [:]
    /// Maps an externally-issued streamId to its canonical pool key.
    var streamToKey: [UUID: String] = [:]
    /// Maps a previously-seen pool key (e.g. AppState's "pending-…" key) to
    /// the canonical key (the agent's `session/new` sessionId). Used to
    /// resolve subsequent turns whose `clientSessionKey` was renamed by
    /// AppState's session-id reconciliation.
    var aliasToCanonical: [String: String] = [:]

    /// Reference to the permission server for bridging `session/request_permission`.
    weak var permissionServer: PermissionServer?

    /// Cached PATH read from the user's interactive login shell, so spawned
    /// `npx`/`uvx`/binary agents can locate `node` and friends when the host
    /// app was launched from Finder with the minimal GUI PATH.
    var cachedShellPath: String?

    init() {}

    func setPermissionServer(_ server: PermissionServer) {
        self.permissionServer = server
    }

    // MARK: - Pool Lifecycle

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
    func killSession(key: String) {
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

    // MARK: - Process Lifecycle

    func startStderrReader(key: String, stderr: FileHandle) {
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

    func appendStderr(key: String, line: String) {
        let resolved = aliasToCanonical[key] ?? key
        mutateSession(resolved) { $0.stderr += line + "\n" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            logger.info("[ACP][stderr] \(trimmed, privacy: .public)")
        }
    }

    func handleProcessExit(key: String) {
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
