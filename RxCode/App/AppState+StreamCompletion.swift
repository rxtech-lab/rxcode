import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Stream Completion (cross-project MCP)

    /// Record that the stream `streamId` finished. If a caller is already
    /// waiting via `awaitStreamCompletion(...)`, the result is handed to it
    /// directly so it can return immediately; otherwise it's parked in
    /// `pendingStreamCompletions` until someone picks it up.
    func recordStreamCompletion(
        streamId: UUID,
        sessionId: String,
        assistantText: String,
        error: String?
    ) {
        guard recordedStreamCompletionIds.insert(streamId).inserted else {
            logger.info("[IDE_SEND_THREAD] ignoring duplicate stream completion stream=\(streamId) session=\(sessionId, privacy: .public)")
            return
        }
        logger.info("[IDE_SEND_THREAD] record stream completion stream=\(streamId) session=\(sessionId, privacy: .public) error=\(error ?? "<nil>", privacy: .public) assistantChars=\(assistantText.count, privacy: .public)")
        if error == nil {
            reconcileTaskCompletionLabel(sessionId: sessionId, assistantText: assistantText)
        }
        broadcastMobileTaskReview(sessionId: sessionId)
        let completion = StreamCompletion(
            sessionId: sessionId,
            assistantText: assistantText,
            error: error,
            isFinal: true
        )
        if let waiter = streamCompletionWaiters.removeValue(forKey: streamId) {
            logger.info("[IDE_SEND_THREAD] resuming stream completion waiter stream=\(streamId) session=\(sessionId, privacy: .public)")
            waiter.resume(with: completion)
            return
        }
        if streamPartialResponseDeliveredIds.contains(streamId) {
            logger.info("[IDE_SEND_THREAD] final stream completion already delivered partially stream=\(streamId) session=\(sessionId, privacy: .public)")
            return
        }
        logger.info("[IDE_SEND_THREAD] parking stream completion stream=\(streamId) session=\(sessionId, privacy: .public)")
        pendingStreamCompletions[streamId] = completion
    }

    /// Resume an inline `ide__send_to_thread` waiter with the first visible
    /// assistant text without marking the target stream finished. The normal
    /// `.result` path still runs and records final cleanup later.
    func recordStreamPartialResponse(
        streamId: UUID,
        sessionId: String,
        assistantText: String
    ) {
        let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let waiter = streamCompletionWaiters[streamId], waiter.acceptsPartial else { return }
        streamCompletionWaiters.removeValue(forKey: streamId)
        streamPartialResponseDeliveredIds.insert(streamId)
        logger.info("[IDE_SEND_THREAD] resuming stream waiter with partial assistant text stream=\(streamId) session=\(sessionId, privacy: .public) assistantChars=\(assistantText.count, privacy: .public)")
        waiter.resume(with: StreamCompletion(
            sessionId: sessionId,
            assistantText: assistantText,
            error: nil,
            isFinal: false
        ))
    }

    func recordStreamPartialResponseIfNeeded(streamId: UUID, sessionId: String) {
        guard let waiter = streamCompletionWaiters[streamId], waiter.acceptsPartial else { return }
        guard let state = sessionStates[sessionId],
              !state.textDeltaBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        flushPendingUpdates(for: sessionId, forceText: true)
        let assistantText = lastAssistantResponseText(in: stateForSession(sessionId).messages)
        recordStreamPartialResponse(
            streamId: streamId,
            sessionId: sessionId,
            assistantText: assistantText
        )
    }

    /// Wait up to `timeout` seconds for the stream identified by `streamId`
    /// to record a completion. Event-driven: `recordStreamCompletion` resumes
    /// the continuation as soon as the result lands, with a parallel
    /// `Task.sleep(timeout)` to surface `nil` if the deadline passes first.
    /// Returns the completion if one arrived in time, otherwise `nil`.
    func awaitStreamCompletion(
        streamId: UUID,
        timeout: TimeInterval,
        acceptsPartial: Bool = true
    ) async -> StreamCompletion? {
        // Fast path — completion already landed before we registered.
        if let completion = pendingStreamCompletions.removeValue(forKey: streamId) {
            logger.info("[IDE_SEND_THREAD] consumed parked stream completion stream=\(streamId) session=\(completion.sessionId, privacy: .public)")
            return completion
        }

        logger.info("[IDE_SEND_THREAD] registering stream completion waiter stream=\(streamId) timeout=\(String(format: "%.1f", timeout), privacy: .public)s")
        let timeoutTask = Task { [weak self] in
            let nanos = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self else { return }
            await MainActor.run {
                if let waiter = self.streamCompletionWaiters.removeValue(forKey: streamId) {
                    self.logger.warning("[IDE_SEND_THREAD] stream completion waiter timed out stream=\(streamId)")
                    waiter.resume(with: nil)
                }
            }
        }

        let result: StreamCompletion? = await withCheckedContinuation { cont in
            let waiter = StreamCompletionWaiter(continuation: cont, acceptsPartial: acceptsPartial)
            // Re-check between the fast-path read and continuation install — the
            // recorder may have fired in between if any MainActor work yielded.
            if let completion = pendingStreamCompletions.removeValue(forKey: streamId) {
                logger.info("[IDE_SEND_THREAD] consumed stream completion during waiter install stream=\(streamId) session=\(completion.sessionId, privacy: .public)")
                waiter.resume(with: completion)
            } else {
                streamCompletionWaiters[streamId] = waiter
            }
        }

        timeoutTask.cancel()
        logger.info("[IDE_SEND_THREAD] stream completion wait finished stream=\(streamId) resultSession=\(result?.sessionId ?? "<timeout>", privacy: .public)")
        return result
    }

    /// Discard a recorded completion. Called by long-running `wait_for_response=false`
    /// MCP sends so the dictionary doesn't grow unbounded with abandoned results.
    func discardStreamCompletion(streamId: UUID) {
        logger.info("[IDE_SEND_THREAD] discarding stream completion stream=\(streamId)")
        pendingStreamCompletions.removeValue(forKey: streamId)
        recordedStreamCompletionIds.remove(streamId)
        streamPartialResponseDeliveredIds.remove(streamId)
        if let waiter = streamCompletionWaiters.removeValue(forKey: streamId) {
            waiter.resume(with: nil)
        }
    }

    // MARK: - Session-id rename handoff (cross-project MCP)

    /// Record that `pendingKey` was renamed to `realSessionId` (the CLI's own
    /// `session_id`). Mirror writes to `sessionIdRedirect` already; this also
    /// resumes any `awaitSessionRename` caller so the cross-project send can
    /// return the real thread id instead of `pending-…`.
    // MARK: - Per-provider native session ids

    /// Record a backend-reported native session id for `provider` on `threadId`,
    /// updating both the in-memory session state and the persisted thread row so
    /// a later provider switch can resume the correct native session (or, for a
    /// provider that has never run on this thread, start a fresh one).
    func recordProviderSessionId(_ provider: AgentProvider, nativeId: String, threadId: String) {
        guard !nativeId.isEmpty else { return }
        updateState(threadId) { state in
            state.providerSessionIds[provider.rawValue] = nativeId
        }
        threadStore.setProviderSessionId(
            localId: threadId,
            providerRaw: provider.rawValue,
            nativeId: nativeId
        )
    }

    /// The per-provider native-id map for a thread, preferring in-memory session
    /// state and falling back to the persisted row.
    func providerSessionIdMap(for threadId: String) -> [String: String] {
        let inMemory = sessionStates[threadId]?.providerSessionIds ?? [:]
        if !inMemory.isEmpty { return inMemory }
        return threadStore.providerSessionIds(forLocalId: threadId)
    }

    /// Whether `provider` owns `threadId`'s identity — i.e. the thread id is that
    /// provider's own native session id. True for the provider that first created
    /// the thread (and for brand-new threads with no map yet); false for a
    /// provider the user switched to mid-thread. Decides whether a
    /// backend-reported id should rename the thread (owner) or just be recorded
    /// as an alternate native id (switched provider).
    func providerOwnsThreadId(_ provider: AgentProvider, threadId: String) -> Bool {
        let map = providerSessionIdMap(for: threadId)
        if map.isEmpty { return true }
        return map[provider.rawValue] == threadId
    }

    /// The native session id to resume for `provider` on `threadId`, or `nil` to
    /// start a fresh native session. A provider that has run here resumes its own
    /// recorded id; a provider new to the thread starts fresh; a legacy thread
    /// with no map at all resumes on its own id (preserving prior behavior).
    func resumeSessionId(for provider: AgentProvider, threadId: String) -> String? {
        let map = providerSessionIdMap(for: threadId)
        if let id = map[provider.rawValue] { return id }
        // No native id recorded for this provider. If the thread has no map at
        // all it predates per-provider ids and resumes on its own id; otherwise
        // this provider has never run here and must start a fresh session.
        return map.isEmpty ? threadId : nil
    }

    func applySessionIdRedirect(from pendingKey: String, to realSessionId: String) {
        logger.info("[IDE_SEND_THREAD] session id redirect pendingKey=\(pendingKey, privacy: .public) realSession=\(realSessionId, privacy: .public)")
        sessionIdRedirect[pendingKey] = realSessionId
        if let branches = ciBranchesBySessionId.removeValue(forKey: pendingKey) {
            ciBranchesBySessionId[realSessionId] = branches
        }
        if let pullRequest = branchStatus.inferredBySession.removeValue(forKey: pendingKey) {
            branchStatus.inferredBySession[realSessionId] = pullRequest
            Task { await persistBranchStatus() }
        }
        Task { await CodingAnalyticsRecorder.shared.redirect(from: pendingKey, to: realSessionId) }
        if let waiter = sessionIdRenameWaiters.removeValue(forKey: pendingKey) {
            logger.info("[IDE_SEND_THREAD] resuming session rename waiter pendingKey=\(pendingKey, privacy: .public) realSession=\(realSessionId, privacy: .public)")
            waiter.resume(with: realSessionId)
        }
    }

    /// Wait up to `timeout` seconds for `pendingKey` to be renamed to the
    /// CLI's real `session_id`. Fast-paths the answer if the rename already
    /// landed. Returns `nil` on timeout.
    func awaitSessionRename(pendingKey: String, timeout: TimeInterval) async -> String? {
        if let real = sessionIdRedirect[pendingKey] {
            logger.info("[IDE_SEND_THREAD] consumed existing session redirect pendingKey=\(pendingKey, privacy: .public) realSession=\(real, privacy: .public)")
            return real
        }

        logger.info("[IDE_SEND_THREAD] registering session rename waiter pendingKey=\(pendingKey, privacy: .public) timeout=\(String(format: "%.1f", timeout), privacy: .public)s")
        let timeoutTask = Task { [weak self] in
            let nanos = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self else { return }
            await MainActor.run {
                if let waiter = self.sessionIdRenameWaiters.removeValue(forKey: pendingKey) {
                    self.logger.warning("[IDE_SEND_THREAD] session rename waiter timed out pendingKey=\(pendingKey, privacy: .public)")
                    waiter.resume(with: nil)
                }
            }
        }

        let result: String? = await withCheckedContinuation { cont in
            let waiter = SessionRenameWaiter(continuation: cont)
            if let real = sessionIdRedirect[pendingKey] {
                logger.info("[IDE_SEND_THREAD] consumed session redirect during waiter install pendingKey=\(pendingKey, privacy: .public) realSession=\(real, privacy: .public)")
                waiter.resume(with: real)
            } else {
                sessionIdRenameWaiters[pendingKey] = waiter
            }
        }

        timeoutTask.cancel()
        logger.info("[IDE_SEND_THREAD] session rename wait finished pendingKey=\(pendingKey, privacy: .public) realSession=\(result ?? "<timeout>", privacy: .public)")
        return result
    }
}
