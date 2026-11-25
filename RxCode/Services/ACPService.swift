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
        // A retry can reuse the thread key before the old process exits.
        let generation = UUID()
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
        var supportsHostOwnedSteering = false

        // Per-turn (reset before `session/prompt`)
        var currentStreamId: UUID?
        var continuation: AsyncStream<StreamEvent>.Continuation?
        var promptRequestId: Int?
        var cancellationRequested = false
        var permissionRequests: [JSONValue: Task<Void, Never>] = [:]
        var steering: SteeringRequest?
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
        var hasDebateQuestionTool = false
    }

    var sessions: [String: SessionEntry] = [:]
    var completedErrors: [UUID: String] = [:]
    var turnTasks: [UUID: Task<Void, Never>] = [:]
    var startingTurns: [String: UUID] = [:]
    var turnWaiters: [UUID: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    /// Maps an externally-issued streamId to its canonical pool key.
    var streamToKey: [UUID: String] = [:]
    /// Maps a previously-seen pool key (e.g. AppState's "pending-…" key) to
    /// the canonical key (the agent's `session/new` sessionId). Used to
    /// resolve subsequent turns whose `clientSessionKey` was renamed by
    /// AppState's session-id reconciliation.
    var aliasToCanonical: [String: String] = [:]

    /// Reference to the permission server for bridging `session/request_permission`.
    weak var permissionServer: PermissionServer?

    init() {}

    func setPermissionServer(_ server: PermissionServer) {
        self.permissionServer = server
    }

    func rootPid(for streamId: UUID) -> Int32? {
        guard let key = streamToKey[streamId],
              let proc = sessions[key]?.process,
              proc.isRunning else { return nil }
        return proc.processIdentifier
    }

    // MARK: - Pool Lifecycle

    /// The turn owns its wire lifetime even when the transcript consumer stops.
    func finalize(streamId: UUID) {
        guard turnTasks[streamId] == nil else { return }
        releaseStream(streamId: streamId)
    }

    func releaseStream(streamId: UUID) {
        guard let key = streamToKey.removeValue(forKey: streamId) else { return }
        if sessions[key]?.currentStreamId == streamId { cancelPermissionRequests(key: key) }
        guard var entry = sessions[key] else { return }
        if entry.currentStreamId == streamId {
            entry.currentStreamId = nil
            entry.continuation = nil
            entry.promptRequestId = nil
            entry.cancellationRequested = false
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

    /// ACP v1 acknowledges cancellation in the original prompt response.
    /// Keep its request and session slot until that response arrives.
    func cancel(streamId: UUID) {
        guard let key = streamToKey[streamId],
              let entry = sessions[key], entry.currentStreamId == streamId else {
            turnTasks[streamId]?.cancel()
            return
        }
        guard !entry.cancellationRequested else { return }
        guard let agentSid = entry.agentSessionId, entry.promptRequestId != nil else {
            // No prompt has started. Cancel only an in-progress setup.
            turnTasks[streamId]?.cancel()
            if entry.agentSessionId == nil || entry.isEphemeral {
                killSession(key: key)
            } else {
                releaseStream(streamId: streamId)
            }
            return
        }
        guard entry.acceptingUpdates else { return }
        mutateSession(key) { $0.cancellationRequested = true }
        do {
            try writeFrame(key: key, frame: .object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/cancel"),
                "params": .object(["sessionId": .string(agentSid)])
            ]))
        } catch {
            logger.warning("[ACP] cancellation write failed: \(error.localizedDescription, privacy: .public)")
        }
        cancelPermissionRequests(key: key)
    }

    func waitForTurnEnd(streamId: UUID, timeout: Duration = .seconds(10)) async -> Bool {
        guard turnTasks[streamId] != nil else { return true }
        let waiterId = UUID()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            finishTurnWaiter(streamId: streamId, waiterId: waiterId)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                turnWaiters[streamId, default: [:]][waiterId] = continuation
            }
        } onCancel: {
            Task { await self.finishTurnWaiter(streamId: streamId, waiterId: waiterId) }
        }
    }

    func prepareQueuedFollowUp(cancelling streamId: UUID?, sessionKey: String, requiresSession: Bool) async -> Bool {
        let key = streamId.flatMap { streamToKey[$0] } ?? aliasToCanonical[sessionKey] ?? sessionKey
        let generation = sessions[key].flatMap { $0.agentSessionId == nil ? nil : $0.generation }
        let pendingStream = streamId ?? sessions[key]?.currentStreamId ?? startingTurns[key]
        if let streamId { cancel(streamId: streamId) }
        if let pendingStream, !(await waitForTurnEnd(streamId: pendingStream)) { return false }
        guard let generation else { return !requiresSession }
        return sessions[key]?.generation == generation && sessions[key]?.process.isRunning == true
    }

    private func finishTurnWaiter(streamId: UUID, waiterId: UUID) {
        let waiter = turnWaiters[streamId]?.removeValue(forKey: waiterId)
        if turnWaiters[streamId]?.isEmpty == true { turnWaiters.removeValue(forKey: streamId) }
        waiter?.resume(returning: false)
    }

    func finishTurn(streamId: UUID) {
        releaseStream(streamId: streamId)
        turnTasks.removeValue(forKey: streamId)
        if let waiters = turnWaiters.removeValue(forKey: streamId) {
            for waiter in waiters.values { waiter.resume(returning: true) }
        }
    }

    func consumeStderr(for streamId: UUID) -> String? {
        if let error = completedErrors.removeValue(forKey: streamId) { return error }
        guard let key = streamToKey[streamId], let entry = sessions[key] else {
            return nil
        }
        let trimmed = entry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cleanup() {
        for task in turnTasks.values { task.cancel() }
        for (key, _) in sessions {
            killSession(key: key)
        }
        sessions.removeAll()
        streamToKey.removeAll()
        aliasToCanonical.removeAll()
        completedErrors.removeAll()
    }

    /// Tear down a pooled session — terminate the process and forget all
    /// references. Used by `cleanup()`, ephemeral probe sessions, and as a
    /// recovery path when a pooled process dies between turns.
    func killSession(key: String) {
        finishSteering(key: key, outcome: .unconfirmed)
        cancelPermissionRequests(key: key)
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
        if let sid = entry.currentStreamId {
            streamToKey.removeValue(forKey: sid)
        }
        // Drop any aliases that pointed at this canonical key so future
        // lookups don't follow a dangling entry.
        let aliases = aliasToCanonical.filter { $0.value == key }.map(\.key)
        for alias in aliases { aliasToCanonical.removeValue(forKey: alias) }
    }

    // MARK: - Process Lifecycle

    func startStderrReader(key: String, generation: UUID, stderr: FileHandle) {
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
                    await self?.appendProcessStderr(key: key, generation: generation, line: line)
                }
            }
        }
    }

    func appendProcessStderr(key: String, generation: UUID, line: String) {
        let resolved = aliasToCanonical[key] ?? key
        guard sessions[resolved]?.generation == generation else { return }
        appendStderr(key: resolved, line: line)
    }

    func appendStderr(key: String, line: String) {
        let resolved = aliasToCanonical[key] ?? key
        mutateSession(resolved) { $0.stderr += line + "\n" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            logger.info("[ACP][stderr] \(trimmed, privacy: .public)")
        }
    }

    func handleProcessExit(key: String, generation: UUID) {
        let resolved = aliasToCanonical[key] ?? key
        guard let entry = sessions[resolved], entry.generation == generation else { return }
        logger.info("[ACP] process exit pid=\(entry.process.processIdentifier) status=\(entry.process.terminationStatus) reason=\(String(describing: entry.process.terminationReason.rawValue), privacy: .public) pending=\(entry.pending.count) client=\(entry.spec.displayName, privacy: .public)")
        for (_, cont) in entry.pending {
            cont.resume(throwing: ACPError.processExited(code: entry.process.terminationStatus))
        }
        mutateSession(resolved) { $0.pending.removeAll() }
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
    case authRequired(clientName: String)
    case previousTurnUnconfirmed

    /// JSON-RPC error code ACP agents return when a request needs sign-in.
    static let authRequiredCode = -32000

    var errorDescription: String? {
        switch self {
        case .streamClosed: return "ACP stream closed"
        case .protocolMismatch(let msg): return "ACP protocol mismatch: \(msg)"
        case .agentError(let code, let msg): return "ACP agent error \(code): \(msg)"
        case .processExited(let code): return "ACP agent exited (code \(code))"
        case .probeTimeout(let s): return "ACP agent did not respond within \(s)s"
        case .authRequired(let name): return "\(name) requires sign-in. Open Settings → Agent and choose Manage → Sign In…"
        case .previousTurnUnconfirmed: return "The ACP client hasn’t confirmed that the previous response ended."
        }
    }
}
