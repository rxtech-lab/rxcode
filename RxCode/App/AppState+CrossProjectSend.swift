import Foundation
import os
import RxCodeCore

extension AppState {
    // MARK: - Cross-Project Send (used by ide__send_to_thread)

    struct CrossProjectSendResult: Sendable {
        let threadId: String
        let projectId: UUID
        let done: Bool
        let assistantText: String
        let error: String?
    }

    enum CrossProjectSendError: Error, LocalizedError {
        case unknownProject(UUID)
        case unknownThread(String)

        var errorDescription: String? {
            switch self {
            case .unknownProject(let id): return "No project with id \(id.uuidString)"
            case .unknownThread(let id):  return "No thread with id \(id)"
            }
        }
    }

    /// Send a prompt to a thread in any project. The send runs through the
    /// normal `sendPrompt` pipeline via a synthetic `WindowState`, so all the
    /// usual side-effects (title generation, briefing updates, persistence)
    /// still fire and any UI windows currently bound to the same session see
    /// the assistant tokens live via the shared `sessionStates` dictionary.
    func sendCrossProject(
        projectId: UUID?,
        threadId: String?,
        prompt: String,
        agentProvider: AgentProvider? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        waitForResponse: Bool = true,
        timeoutSeconds: TimeInterval = 120,
        parentThreadId: String? = nil,
        threadLabel: String? = nil,
        skipHooks: Bool = false,
        setupKind: String? = nil,
        includeIDEMCP: Bool = true
    ) async throws -> CrossProjectSendResult {
        logger.info("[IDE_SEND_THREAD] requested projectId=\(projectId?.uuidString ?? "<nil>", privacy: .public) threadId=\(threadId ?? "<nil>", privacy: .public) wait=\(waitForResponse, privacy: .public) timeout=\(String(format: "%.1f", timeoutSeconds), privacy: .public)s provider=\(agentProvider?.rawValue ?? "<default>", privacy: .public) includeIDEMCP=\(includeIDEMCP, privacy: .public) promptChars=\(prompt.count, privacy: .public)")

        // Resolve target project + thread.
        let resolvedProject: Project
        let resolvedThreadId: String?

        if let threadId {
            guard let summary = allSessionSummaries.first(where: { $0.id == threadId })
                ?? threadStore.fetch(id: threadId).map({ $0.toSummary() })
            else {
                throw CrossProjectSendError.unknownThread(threadId)
            }
            guard let proj = projects.first(where: { $0.id == summary.projectId }) else {
                throw CrossProjectSendError.unknownProject(summary.projectId)
            }
            resolvedProject = proj
            resolvedThreadId = threadId
        } else if let projectId {
            guard let proj = projects.first(where: { $0.id == projectId }) else {
                throw CrossProjectSendError.unknownProject(projectId)
            }
            resolvedProject = proj
            resolvedThreadId = nil
        } else {
            throw CrossProjectSendError.unknownProject(UUID())
        }
        logger.info("[IDE_SEND_THREAD] target resolved project=\(resolvedProject.id.uuidString, privacy: .public) path=\(resolvedProject.path, privacy: .public) thread=\(resolvedThreadId ?? "<new>", privacy: .public)")

        // Build a synthetic WindowState. AppState.sessionStates is shared across
        // windows, so the message + stream are visible to any real window that
        // happens to also be viewing this session.
        let window = WindowState()
        window.selectedProject = resolvedProject
        window.currentSessionId = resolvedThreadId

        // Carry over per-session overrides for a new thread; for an existing
        // thread we leave the session's own stored values alone (the resume
        // path in sendPrompt reads from `sessionStates[sessionKey]`).
        if resolvedThreadId == nil {
            if let agentProvider {
                window.sessionAgentProvider = agentProvider
            }
            if let model {
                window.sessionModel = model
            }
            if let effort {
                window.sessionEffort = effort
            }
            if let permissionMode {
                window.sessionPermissionMode = permissionMode
            }
        }

        guard let streamId = await sendPrompt(
            prompt,
            displayText: prompt,
            debugLogPrefix: "[IDE_SEND_THREAD]",
            includeIDEMCP: includeIDEMCP,
            in: window
        ) else {
            logger.error("[IDE_SEND_THREAD] sendPrompt failed project=\(resolvedProject.id.uuidString, privacy: .public) requestedThread=\(resolvedThreadId ?? "<new>", privacy: .public)")
            return CrossProjectSendResult(
                threadId: resolvedThreadId ?? "",
                projectId: resolvedProject.id,
                done: false,
                assistantText: "",
                error: "Send failed: no session could be allocated."
            )
        }
        logger.info("[IDE_SEND_THREAD] stream allocated stream=\(streamId) project=\(resolvedProject.id.uuidString, privacy: .public) initialKey=\(window.currentSessionId ?? "<nil>", privacy: .public) requestedThread=\(resolvedThreadId ?? "<new>", privacy: .public)")

        // After sendPrompt returns, window.currentSessionId is the (possibly
        // pending-) key the stream is bound to. Resolve the real CLI session
        // id before returning so the caller's agent never sees `pending-...`
        // (which it can't use to follow up via `get_thread_messages` etc.).
        let postSendKey = window.currentSessionId ?? resolvedThreadId ?? ""
        if let setupKind {
            setupSessionKeys[setupKind, default: []].insert(postSendKey)
        }
        let resolvedThreadIdForReturn: String
        if postSendKey.hasPrefix("pending-") {
            // Cap the rename wait at the request's timeout so we still honor
            // the caller's deadline; 60s upper bound matches typical first-token
            // latency under healthy conditions.
            let renameTimeout = min(max(timeoutSeconds, 1), 60)
            logger.info("[IDE_SEND_THREAD] waiting for session rename pendingKey=\(postSendKey, privacy: .public) stream=\(streamId) timeout=\(String(format: "%.1f", renameTimeout), privacy: .public)s")
            resolvedThreadIdForReturn = await awaitSessionRename(
                pendingKey: postSendKey,
                timeout: renameTimeout
            ) ?? postSendKey
            if resolvedThreadIdForReturn == postSendKey {
                logger.warning("[IDE_SEND_THREAD] session rename timed out pendingKey=\(postSendKey, privacy: .public) stream=\(streamId)")
            } else {
                logger.info("[IDE_SEND_THREAD] session rename resolved pendingKey=\(postSendKey, privacy: .public) realThread=\(resolvedThreadIdForReturn, privacy: .public) stream=\(streamId)")
            }
        } else {
            resolvedThreadIdForReturn = postSendKey
            logger.info("[IDE_SEND_THREAD] using existing session key thread=\(resolvedThreadIdForReturn, privacy: .public) stream=\(streamId)")
        }
        if let setupKind, resolvedThreadIdForReturn != postSendKey {
            setupSessionKeys[setupKind, default: []].insert(resolvedThreadIdForReturn)
        }

        // Stamp linkage (parent thread / label / skip-hooks) onto the freshly
        // created thread now that its real id is known. Only for new threads —
        // existing-thread sends (e.g. the commit message) leave linkage alone.
        if resolvedThreadId == nil,
           parentThreadId != nil || threadLabel != nil || skipHooks {
            threadStore.setThreadLinkage(
                sessionId: resolvedThreadIdForReturn,
                parentThreadId: parentThreadId,
                threadLabel: threadLabel,
                skipHooks: skipHooks
            )
            // Mirror onto the in-memory summary so the UI reflects it immediately.
            if let idx = allSessionSummaries.firstIndex(where: { $0.id == resolvedThreadIdForReturn }) {
                allSessionSummaries[idx].parentThreadId = parentThreadId
                allSessionSummaries[idx].threadLabel = threadLabel
                allSessionSummaries[idx].skipHooks = skipHooks
            }
            // If this is the spawned code-review thread, hand its now-known
            // session id to the scheduler so a cancellation (new message / Stop)
            // can interrupt the exact in-flight review — and apply a stop that
            // was requested before the id was known. Runs before the response is
            // awaited below, closing the startup race.
            if threadLabel == Self.manualCodeReviewLabel, let parent = parentThreadId {
                reviewScheduler?.registerRunningReviewThread(parentSessionKey: parent, reviewThreadId: resolvedThreadIdForReturn)
            }
        }

        if !waitForResponse {
            // Don't leak the result in the dictionary; the caller is
            // fire-and-forget. Drop it once it lands.
            logger.info("[IDE_SEND_THREAD] returning without waiting stream=\(streamId) thread=\(resolvedThreadIdForReturn, privacy: .public)")
            Task { [weak self] in
                _ = await self?.awaitStreamCompletion(
                    streamId: streamId,
                    timeout: timeoutSeconds,
                    acceptsPartial: false
                )
            }
            return CrossProjectSendResult(
                threadId: resolvedThreadIdForReturn,
                projectId: resolvedProject.id,
                done: false,
                assistantText: "",
                error: nil
            )
        }

        logger.info("[IDE_SEND_THREAD] waiting for stream completion stream=\(streamId) thread=\(resolvedThreadIdForReturn, privacy: .public) timeout=\(String(format: "%.1f", timeoutSeconds), privacy: .public)s")
        let completion = await awaitStreamCompletion(
            streamId: streamId,
            timeout: timeoutSeconds,
            acceptsPartial: false
        )
        if let completion {
            logger.info("[IDE_SEND_THREAD] stream completion received stream=\(streamId) session=\(completion.sessionId, privacy: .public) error=\(completion.error ?? "<nil>", privacy: .public) assistantChars=\(completion.assistantText.count, privacy: .public)")
            return CrossProjectSendResult(
                threadId: completion.sessionId,
                projectId: resolvedProject.id,
                done: completion.isFinal && completion.error == nil,
                assistantText: completion.assistantText,
                error: completion.error
            )
        } else {
            // Timed out. Surface the partial assistant text we have so far so
            // the caller can decide whether to poll back via get_thread_messages.
            let partial = lastAssistantResponseText(in: stateForSession(window.currentSessionId ?? "").messages)
            logger.warning("[IDE_SEND_THREAD] stream completion timed out stream=\(streamId) thread=\(resolvedThreadIdForReturn, privacy: .public) currentKey=\(window.currentSessionId ?? "<nil>", privacy: .public) partialChars=\(partial.count, privacy: .public)")
            return CrossProjectSendResult(
                threadId: resolvedThreadIdForReturn,
                projectId: resolvedProject.id,
                done: false,
                assistantText: partial,
                error: nil
            )
        }
    }
}
