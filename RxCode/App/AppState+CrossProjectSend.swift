import Foundation
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
        setupKind: String? = nil
    ) async throws -> CrossProjectSendResult {
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

        guard let streamId = await sendPrompt(prompt, displayText: prompt, in: window) else {
            return CrossProjectSendResult(
                threadId: resolvedThreadId ?? "",
                projectId: resolvedProject.id,
                done: false,
                assistantText: "",
                error: "Send failed: no session could be allocated."
            )
        }

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
            resolvedThreadIdForReturn = await awaitSessionRename(
                pendingKey: postSendKey,
                timeout: renameTimeout
            ) ?? postSendKey
        } else {
            resolvedThreadIdForReturn = postSendKey
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
        }

        if !waitForResponse {
            // Don't leak the result in the dictionary; the caller is
            // fire-and-forget. Drop it once it lands.
            Task { [weak self] in
                _ = await self?.awaitStreamCompletion(streamId: streamId, timeout: timeoutSeconds)
            }
            return CrossProjectSendResult(
                threadId: resolvedThreadIdForReturn,
                projectId: resolvedProject.id,
                done: false,
                assistantText: "",
                error: nil
            )
        }

        let completion = await awaitStreamCompletion(streamId: streamId, timeout: timeoutSeconds)
        if let completion {
            return CrossProjectSendResult(
                threadId: completion.sessionId,
                projectId: resolvedProject.id,
                done: completion.error == nil,
                assistantText: completion.assistantText,
                error: completion.error
            )
        } else {
            // Timed out. Surface the partial assistant text we have so far so
            // the caller can decide whether to poll back via get_thread_messages.
            let partial = lastAssistantResponseText(in: stateForSession(window.currentSessionId ?? "").messages)
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
