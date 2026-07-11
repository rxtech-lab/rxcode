import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    func processStream(
        streamId: UUID,
        prompt: String,
        cwd: String,
        cliSessionId: String?,
        internalSessionKey: String,
        agentProvider: AgentProvider,
        model: String?,
        effort: String? = nil,
        hookSettingsPath: String?,
        permissionMode: PermissionMode = .default,
        hookSessionMode: PermissionMode? = nil,
        projectId: UUID,
        includeIDEMCP: Bool = true,
        window: WindowState
    ) async {
        // Mode used when registering a session with PermissionServer for hook auto-approve.
        // When plan toggle is on, `permissionMode` is `.plan` (for the CLI flag) but the
        // user's dropdown choice (e.g. `.auto`) should still drive the hook policy.
        let registerMode = hookSessionMode ?? permissionMode
        let streamStart = Date()
        let debugLogPrefix = streamDebugLogPrefixes[streamId]
        logger.info("[Stream:UI] starting processStream provider=\(agentProvider.rawValue, privacy: .public) stream=\(streamId) cli=\(cliSessionId ?? "new", privacy: .public) key=\(internalSessionKey, privacy: .public)")
        if let debugLogPrefix {
            logger.info("\(debugLogPrefix, privacy: .public) phase=processStreamStart stream=\(streamId) provider=\(agentProvider.rawValue, privacy: .public) cli=\(cliSessionId ?? "new", privacy: .public) key=\(internalSessionKey, privacy: .public)")
        }

        var sessionKey = internalSessionKey

        // Resolve per-backend send-request fields (MCP injection, ACP client
        // spec, model split, background context) concurrently before dispatching
        // through the unified protocol. See `resolveStreamPreflight`.
        let preflight = await resolveStreamPreflight(
            streamId: streamId,
            prompt: prompt,
            cwd: cwd,
            cliSessionId: cliSessionId,
            sessionKey: sessionKey,
            agentProvider: agentProvider,
            model: model,
            permissionMode: permissionMode,
            registerMode: registerMode,
            projectId: projectId,
            includeIDEMCP: includeIDEMCP,
            streamStart: streamStart
        )

        let stream: AsyncStream<StreamEvent>
        if let earlyStream = preflight.earlyStream {
            stream = earlyStream
        } else {
            let preflightElapsed = Date().timeIntervalSince(streamStart)
            logger.info("[Stream:UI] backend send starting provider=\(agentProvider.rawValue, privacy: .public) stream=\(streamId) after=\(String(format: "%.2f", preflightElapsed), privacy: .public)s cwd=\(cwd, privacy: .public)")
            if let debugLogPrefix {
                logger.info("\(debugLogPrefix, privacy: .public) phase=backendSendStart stream=\(streamId) after=\(String(format: "%.2f", preflightElapsed), privacy: .public)s provider=\(agentProvider.rawValue, privacy: .public) cwd=\(cwd, privacy: .public)")
            }
            let request = BackendSendRequest(
                streamId: streamId,
                prompt: preflight.resolvedPrompt,
                cwd: cwd,
                sessionId: cliSessionId,
                model: preflight.resolvedModel,
                effort: effort,
                permissionMode: preflight.resolvedSendMode,
                planMode: permissionMode == .plan,
                hookSettingsPath: hookSettingsPath,
                mcpClaudeConfigPath: preflight.mcpClaudeConfigPath,
                extraSystemPrompt: preflight.extraSystemPrompt,
                mcpCodexOverrides: preflight.mcpCodexOverrides,
                acpMCPServers: preflight.acpMCPServers,
                acpSpec: preflight.acpSpec,
                clientSessionKey: sessionKey
            )
            stream = await backend(for: agentProvider).send(request)
            let backendReturnedElapsed = Date().timeIntervalSince(streamStart)
            logger.info("[Stream:UI] backend send returned provider=\(agentProvider.rawValue, privacy: .public) stream=\(streamId) after=\(String(format: "%.2f", backendReturnedElapsed), privacy: .public)s")
            if let debugLogPrefix {
                logger.info("\(debugLogPrefix, privacy: .public) phase=backendSendReturned stream=\(streamId) after=\(String(format: "%.2f", backendReturnedElapsed), privacy: .public)s provider=\(agentProvider.rawValue, privacy: .public)")
            }
        }

        startFlushTimer(for: sessionKey)

        // Reset the watchdog clock at the start so the first event window is
        // measured from when we actually began awaiting the stream, not from
        // an earlier turn that was finalized on this same session state.
        updateState(sessionKey) { $0.lastStreamEventDate = Date() }
        let watchdogTask = startStreamWatchdog(
            streamId: streamId,
            sessionKey: sessionKey,
            agentProvider: agentProvider,
            in: window
        )
        defer { watchdogTask.cancel() }

        var eventCount = 0
        var lastEventTime = Date()
        logger.info("[Stream:UI] entering for-await session=\(sessionKey, privacy: .public) stream=\(streamId) cwd=\(cwd, privacy: .public)")

        do {
            for await event in stream {
                eventCount += 1
                let gap = Date().timeIntervalSince(lastEventTime)
                if eventCount == 1 {
                    let totalElapsed = Date().timeIntervalSince(streamStart)
                    logger.info("[Stream:UI] first event arrived provider=\(agentProvider.rawValue, privacy: .public) session=\(sessionKey, privacy: .public) stream=\(streamId) total=\(String(format: "%.2f", totalElapsed), privacy: .public)s awaitGap=\(String(format: "%.2f", gap), privacy: .public)s event=\(Self.streamEventLogName(event), privacy: .public)")
                    if let debugLogPrefix {
                        logger.info("\(debugLogPrefix, privacy: .public) phase=firstEvent stream=\(streamId) total=\(String(format: "%.2f", totalElapsed), privacy: .public)s awaitGap=\(String(format: "%.2f", gap), privacy: .public)s event=\(Self.streamEventLogName(event), privacy: .public)")
                    }
                }
                lastEventTime = Date()
                updateState(sessionKey) { $0.lastStreamEventDate = lastEventTime }

                guard !Task.isCancelled else {
                    logger.info("[Stream:UI] task cancelled after \(eventCount) events")
                    break
                }

                let ownsSession = stateForSession(sessionKey).activeStreamId == streamId

                if !ownsSession {
                    if case .result(let resultEvent) = event {
                        logger.info("[Stream:UI] event #\(eventCount) .result received after losing ownership — saving to disk")
                        await finalizeAgentStream(agentProvider: agentProvider, streamId: streamId)
                        if sessionKey != resultEvent.sessionId,
                           providerOwnsThreadId(agentProvider, threadId: sessionKey) {
                            if let state = sessionStates.removeValue(forKey: sessionKey) {
                                sessionStates[resultEvent.sessionId] = state
                            }
                            applySessionIdRedirect(from: sessionKey, to: resultEvent.sessionId)
                            sessionKey = resultEvent.sessionId
                        }
                        recordProviderSessionId(agentProvider, nativeId: resultEvent.sessionId, threadId: sessionKey)
                        let msgs = stateForSession(sessionKey).messages
                        if !msgs.isEmpty {
                            await saveSession(sessionId: sessionKey, projectId: projectId, messages: msgs)
                        }
                    } else {
                        logger.debug("[Stream:UI] event #\(eventCount) — stream \(streamId) no longer owns session \(sessionKey), skipping")
                    }
                    continue
                }

                switch event {
                case .system(let systemEvent):
                    logger.info("[Stream:UI] event #\(eventCount) .system (gap=\(String(format: "%.1f", gap))s)")
                    if let model = systemEvent.model {
                        updateState(sessionKey) { $0.activeModelName = model }
                    }

                    // Track background "backend agent" tasks so a `result` that
                    // merely yields the turn while such a task is still running
                    // doesn't tear the turn down (see the `.result` handler).
                    if let taskId = systemEvent.taskId {
                        let terminalStatuses: Set<String> = ["completed", "killed", "failed", "stopped", "canceled", "cancelled", "timeout", "error"]
                        switch systemEvent.subtype {
                        case "task_started":
                            updateState(sessionKey) { $0.liveBackgroundTaskIds.insert(taskId) }
                            logger.info("[Stream:UI] background task started id=\(taskId, privacy: .public) (live=\(self.stateForSession(sessionKey).liveBackgroundTaskIds.count))")
                        case "task_notification":
                            // A notification is always the task's terminal wake signal.
                            updateState(sessionKey) { $0.liveBackgroundTaskIds.remove(taskId) }
                            logger.info("[Stream:UI] background task notified id=\(taskId, privacy: .public) status=\(systemEvent.taskStatus ?? "?", privacy: .public) (live=\(self.stateForSession(sessionKey).liveBackgroundTaskIds.count))")
                        case "task_updated":
                            if let status = systemEvent.taskStatus, terminalStatuses.contains(status) {
                                updateState(sessionKey) { $0.liveBackgroundTaskIds.remove(taskId) }
                            }
                        default:
                            break
                        }
                    }
                    // Hook events (SessionStart, PreToolUse, etc.) carry the parent's session_id,
                    // not this subprocess's. Acting on them flips currentSessionId mid-stream and
                    // triggers MessageListView's fade-out/in — visible as a blink.
                    let isHookEvent = systemEvent.subtype.hasPrefix("hook_")
                    if let sid = systemEvent.sessionId, !isHookEvent {
                        await permission.registerSession(sid: sid, projectKey: cwd, mode: registerMode)
                        // Only the provider that owns the thread id may re-home the
                        // thread when its native `session_id` changes. A provider
                        // the user switched to mid-thread (e.g. Codex on a Claude
                        // thread) reports its OWN native id here — that must not
                        // rename/reconcile the thread; it's just recorded so a
                        // later switch-back can resume it. `recordProviderSessionId`
                        // runs in both cases below.
                        let streamPlaceholder = "pending-\(streamId.uuidString)"
                        let ownsThreadId = window.pendingPlaceholderIds.contains(streamPlaceholder)
                            || providerOwnsThreadId(agentProvider, threadId: sessionKey)
                        if ownsThreadId {
                        // Capture the sessionKey BEFORE the reassignment so the
                        // reconciler can rename the previous row in place when
                        // the CLI advances `session_id` mid-stream.
                        let previousSessionKey = sessionKey
                        if sessionKey != sid {
                            if let state = sessionStates.removeValue(forKey: previousSessionKey) {
                                sessionStates[sid] = state
                            }
                            renameDraftState(from: previousSessionKey, to: sid, in: window)
                            applySessionIdRedirect(from: previousSessionKey, to: sid)
                            sessionKey = sid
                            startFlushTimer(for: sid)

                            // If this is the foreground session, also update window.currentSessionId.
                            // Do NOT treat `currentSessionId == nil` (the new-thread page) as foreground
                            // for an arbitrary streaming session — that caused the UI to auto-navigate
                            // to a previously-detached thread whenever its CLI advanced its session_id
                            // (e.g. pending→real on first system event, or compact_boundary swap).
                            let isFg = (window.currentSessionId ?? window.newSessionKey) == previousSessionKey
                            if isFg { window.currentSessionId = sid }
                        }

                        let expectedPlaceholder = "pending-\(streamId.uuidString)"
                        if window.pendingPlaceholderIds.contains(expectedPlaceholder),
                           let idx = allSessionSummaries.firstIndex(where: { $0.id == expectedPlaceholder })
                        {
                            let old = allSessionSummaries[idx]
                            // Preserve the placeholder's original timestamp so an empty
                            // session (no assistant content yet) doesn't leapfrog
                            // genuinely-recent chats with an "in 0s" updatedAt. The
                            // first save once content arrives will refresh updatedAt.
                            let replacement = ChatSession(
                                id: sid,
                                projectId: old.projectId,
                                title: old.title,
                                messages: [],
                                createdAt: old.createdAt,
                                updatedAt: old.createdAt,
                                isPinned: old.isPinned,
                                agentProvider: old.agentProvider,
                                model: old.model,
                                effort: old.effort,
                                permissionMode: old.permissionMode,
                                origin: old.origin,
                                worktreePath: old.worktreePath,
                                worktreeBranch: old.worktreeBranch,
                                isArchived: old.isArchived,
                                archivedAt: old.archivedAt
                            )
                            allSessionSummaries.removeAll { $0.id == expectedPlaceholder || $0.id == sid }
                            allSessionSummaries.insert(replacement.summary, at: 0)
                            threadStore.renameId(from: expectedPlaceholder, to: sid)
                            threadStore.upsert(replacement.summary, cliSessionId: sid)
                            window.removePendingPlaceholder(expectedPlaceholder)
                        } else {
                            if window.pendingPlaceholderIds.contains(expectedPlaceholder) {
                                window.removePendingPlaceholder(expectedPlaceholder)
                                allSessionSummaries.removeAll { $0.id == expectedPlaceholder }
                                threadStore.delete(id: expectedPlaceholder)
                            }

                            // A retry reuses the same pending session key (oldKey) with a new streamId,
                            // so expectedPlaceholder won't match oldKey. Clean up the stale placeholder
                            // here to prevent the old entry from persisting as a duplicate in history.
                            let oldKey = sessionKey == sid ? internalSessionKey : sessionKey
                            if oldKey != expectedPlaceholder, window.pendingPlaceholderIds.contains(oldKey) {
                                allSessionSummaries.removeAll { $0.id == oldKey }
                                threadStore.delete(id: oldKey)
                                window.removePendingPlaceholder(oldKey)
                            }

                            // Decide whether to rename the previous row, insert a fresh
                            // one, or do nothing. Renaming in place is the load-bearing
                            // case: it stops empty "New Session" rows from accumulating
                            // every time the CLI advances `session_id` mid-stream (e.g.
                            // after a `compact_boundary`).
                            if let project = projects.first(where: { $0.id == projectId }) {
                                let msgs = stateForSession(sessionKey).messages
                                let firstUser = msgs.first(where: { $0.role == .user })
                                let action = SessionRowReconciler.decide(
                                    newSid: sid,
                                    previousKey: previousSessionKey,
                                    existingIds: Set(allSessionSummaries.map { $0.id }),
                                    firstUserMessageContent: firstUser?.content
                                )
                                switch action {
                                case .noop:
                                    break
                                case .renameInPlace(let from, let to):
                                    if let idx = allSessionSummaries.firstIndex(where: { $0.id == from }) {
                                        let old = allSessionSummaries[idx]
                                        let renamed = ChatSession.Summary(
                                            id: to,
                                            projectId: old.projectId,
                                            title: old.title,
                                            createdAt: old.createdAt,
                                            updatedAt: old.updatedAt,
                                            isPinned: old.isPinned,
                                            agentProvider: old.agentProvider,
                                            model: old.model,
                                            effort: old.effort,
                                            permissionMode: old.permissionMode,
                                            origin: old.origin,
                                            worktreePath: old.worktreePath,
                                            worktreeBranch: old.worktreeBranch,
                                            isArchived: old.isArchived,
                                            archivedAt: old.archivedAt
                                        )
                                        allSessionSummaries.remove(at: idx)
                                        allSessionSummaries.removeAll { $0.id == to }
                                        allSessionSummaries.insert(renamed, at: 0)
                                        threadStore.renameId(from: from, to: to)
                                        threadStore.upsert(renamed, cliSessionId: to)
                                    }
                                case .insertNew(let id, let title):
                                    // Use the user-message timestamp so the row doesn't
                                    // reorder above more recent chats while still empty.
                                    let firstUserDate = firstUser?.timestamp ?? Date()
                                    let inserted = ChatSession.Summary(
                                        id: id,
                                        projectId: project.id,
                                        title: title,
                                        createdAt: firstUserDate,
                                        updatedAt: firstUserDate,
                                        isPinned: false,
                                        agentProvider: agentProvider,
                                        origin: agentProvider.defaultSessionOrigin
                                    )
                                    allSessionSummaries.insert(inserted, at: 0)
                                    threadStore.upsert(inserted, cliSessionId: id)
                                }
                            }
                        }
                        if previousSessionKey != sid {
                            broadcastMobileSessionRedirect(from: previousSessionKey, to: sid)
                        }
                        } // end ownsThreadId
                        // Record this provider's native session id — for the owner
                        // on the possibly-renamed thread id, for a switched provider
                        // on the stable thread id — so each provider can later
                        // resume its own native session.
                        recordProviderSessionId(agentProvider, nativeId: sid, threadId: sessionKey)
                    }

                    if systemEvent.subtype == "compact_boundary" {
                        updateState(sessionKey) { state in
                            state.messages.append(ChatMessage(role: .assistant, content: "Previous conversation has been compacted", isCompactBoundary: true))
                        }
                    }

                case .assistant(let assistantMessage):
                    logger.debug("[Stream:UI] event #\(eventCount) .assistant (gap=\(String(format: "%.1f", gap))s, blocks=\(assistantMessage.content.count))")
                    if assistantMessage.content.contains(where: {
                        if case .thinking = $0 { return true }
                        return false
                    }) {
                        updateState(sessionKey) { $0.isThinking = true }
                    }
                    // A turn can contain several model invocations (one per tool round-trip);
                    // each emits its own `usage.output_tokens` starting from zero. Track the
                    // running max per message id and sum across ids to get the turn total.
                    if let liveOutput = assistantMessage.usage?.outputTokens {
                        updateState(sessionKey) { state in
                            if let messageId = assistantMessage.id {
                                let existing = state.currentTurnOutputTokensByMessage[messageId] ?? 0
                                state.currentTurnOutputTokensByMessage[messageId] = max(existing, liveOutput)
                            } else {
                                state.currentTurnOutputTokensUnkeyed = max(state.currentTurnOutputTokensUnkeyed, liveOutput)
                            }
                        }
                        if agentProvider == .codex {
                            let total = stateForSession(sessionKey).currentTurnOutputTokens
                            logger.info("[Stream:UI] Codex usage applied messageId=\(assistantMessage.id ?? "<nil>", privacy: .public) output=\(liveOutput) total=\(total)")
                        }
                    }
                    // ACP-style providers deliver fully-formed tool_use blocks inside .assistant
                    // events (no content_block_start raw stream). Commit any buffered text first
                    // so tool bubbles appear after — and not in the middle of — the prior text.
                    let hasToolUse = assistantMessage.content.contains {
                        if case .toolUse = $0 { return true }
                        return false
                    }
                    if hasToolUse {
                        flushPendingUpdates(for: sessionKey, forceText: true)
                    }

                    updateState(sessionKey) { state in
                        // Text fallback: only buffer text when no text_delta has been received in
                        // this turn. Normally content_block_delta(text_delta) is the primary path.
                        let canBufferText: Bool = {
                            guard state.textDeltaBuffer.isEmpty else { return false }
                            let afterLastUser = (state.messages.lastIndex(where: { $0.role == .user }).map { $0 + 1 }) ?? 0
                            return !state.messages.suffix(from: afterLastUser).contains {
                                $0.role == .assistant && $0.blocks.contains(where: \.isText)
                            }
                        }()

                        for block in assistantMessage.content {
                            switch block {
                            case .text(let text):
                                if canBufferText, !text.isEmpty {
                                    state.textDeltaBuffer += text
                                }
                            case .toolUse(let id, let name, let input):
                                state.isThinking = false
                                // Kick off a file-content snapshot before any Edit/Write
                                // tool actually runs. The detached read races with the
                                // CLI's file write — on typical small source files the
                                // read wins, giving us the true pre-edit state to diff
                                // against. The persistence step (in `flushPendingUpdates`
                                // when the tool_result lands) awaits this task, so we
                                // capture whatever the read produced even if it lost
                                // the race.
                                Self.captureEditingFileSnapshot(
                                    toolName: name,
                                    input: input,
                                    state: &state
                                )
                                // Merge updates by id: ACP agents may re-emit the same toolUse
                                // with additional input (e.g. diff content arriving via a
                                // follow-up tool_call_update). Patch the existing block in
                                // place so the live edit info reaches `flushPendingUpdates`
                                // when the result lands.
                                if let existingMsgIdx = state.messages.indices.reversed().first(where: {
                                    state.messages[$0].toolCallIndex(id: id) != nil
                                }),
                                   let existingBlockIdx = state.messages[existingMsgIdx].toolCallIndex(id: id) {
                                    var merged = state.messages[existingMsgIdx].blocks[existingBlockIdx].toolCall?.input ?? [:]
                                    for (key, value) in input { merged[key] = value }
                                    state.messages[existingMsgIdx].blocks[existingBlockIdx].toolCall?.input = merged
                                } else {
                                    if state.needsNewMessage {
                                        if let idx = state.messages.indices.reversed().first(where: {
                                            state.messages[$0].role == .assistant && state.messages[$0].isStreaming
                                        }) {
                                            state.messages[idx].isStreaming = false
                                            state.messages[idx].finalizeToolCalls()
                                            Self.stripNoOpText(at: idx, in: &state.messages)
                                        }
                                        state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                                        state.needsNewMessage = false
                                    } else if state.messages.last?.role != .assistant
                                                || !(state.messages.last?.isStreaming ?? false) {
                                        state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                                    }
                                    if let lastIndex = state.messages.indices.last,
                                       state.messages[lastIndex].role == .assistant {
                                        state.messages[lastIndex].appendToolCall(ToolCall(id: id, name: name, input: input))
                                    }
                                }
                            case .thinking:
                                state.isThinking = true
                            }
                        }
                    }
                    recordStreamPartialResponseIfNeeded(streamId: streamId, sessionId: sessionKey)

                case .user(let userMessage):
                    logger.debug("[Stream:UI] event #\(eventCount) .user (gap=\(String(format: "%.1f", gap))s, toolUseId=\(userMessage.toolUseId ?? "none"))")
                    updateState(sessionKey) { state in
                        guard let toolUseId = userMessage.toolUseId else { return }
                        state.pendingToolResults.append((toolUseId, userMessage.content, userMessage.isError))
                        state.needsNewMessage = true
                    }

                case .result(let resultEvent):
                    logger.info("[Stream:UI] event #\(eventCount) .result (gap=\(String(format: "%.1f", gap))s, isError=\(resultEvent.isError), session=\(resultEvent.sessionId))")
                    if let debugLogPrefix {
                        let totalElapsed = Date().timeIntervalSince(streamStart)
                        logger.info("\(debugLogPrefix, privacy: .public) phase=resultEvent stream=\(streamId) eventCount=\(eventCount, privacy: .public) total=\(String(format: "%.2f", totalElapsed), privacy: .public)s gap=\(String(format: "%.1f", gap), privacy: .public)s isError=\(resultEvent.isError, privacy: .public) session=\(resultEvent.sessionId, privacy: .public)")
                    }

                    // Recent Claude Code runs long tasks (background shells, subagents) as
                    // "backend agents". The turn that spawns one ends with a normal `result`
                    // (`origin == null`, `stop_reason == end_turn`) WHILE the task is still
                    // running; when it finishes the CLI autonomously runs a follow-up turn
                    // (a fresh `init` + a `result` with `origin.kind == "task-notification"`).
                    // If we tore the turn down on that yield `result` we'd close stdin — which
                    // kills the still-running CLI/task and loses the follow-up — and flip the
                    // UI to idle. So while any background task is still live, keep the process
                    // alive and the UI "in progress"; only fold in this result's (real) cost.
                    // The follow-up result arrives once tasks drain (set now empty) and takes
                    // the normal end-of-turn path below.
                    if !stateForSession(sessionKey).liveBackgroundTaskIds.isEmpty {
                        let live = stateForSession(sessionKey).liveBackgroundTaskIds.count
                        logger.info("[Stream:UI] event #\(eventCount) .result yields with \(live) live background task(s); keeping turn in progress (origin=\(resultEvent.originKind ?? "none", privacy: .public))")
                        updateState(sessionKey) { state in
                            if let cost = resultEvent.totalCostUsd { state.costUsd = cost }
                            if let duration = resultEvent.durationMs { state.durationMs += duration }
                            if let turns = resultEvent.totalTurns { state.turns += turns }
                            if let usage = resultEvent.usage {
                                state.inputTokens += usage.inputTokens
                                state.outputTokens += usage.outputTokens
                                state.cacheCreationTokens += usage.cacheCreationInputTokens
                                state.cacheReadTokens += usage.cacheReadInputTokens
                            }
                        }
                        break
                    }

                    // With `--input-format stream-json` the CLI stays alive waiting for more
                    // input. Close stdin on `result` so it exits cleanly, then finalize so
                    // any subagent children that survived the parent CLI get reaped.
                    await finalizeAgentStream(agentProvider: agentProvider, streamId: streamId)

                    // Only the provider that owns the thread id may re-home the
                    // thread. A switched provider's differing native id is recorded
                    // (below) but must not rename the thread.
                    let resultOwnsThreadId = window.pendingPlaceholderIds.contains("pending-\(streamId.uuidString)")
                        || providerOwnsThreadId(agentProvider, threadId: sessionKey)
                    if sessionKey != resultEvent.sessionId && resultOwnsThreadId {
                        let previousSessionKey = sessionKey
                        let wasForeground = (window.currentSessionId ?? window.newSessionKey) == previousSessionKey
                        if let state = sessionStates.removeValue(forKey: previousSessionKey) {
                            sessionStates[resultEvent.sessionId] = state
                        }
                        renameDraftState(from: previousSessionKey, to: resultEvent.sessionId, in: window)
                        applySessionIdRedirect(from: previousSessionKey, to: resultEvent.sessionId)
                        sessionKey = resultEvent.sessionId
                        if wasForeground {
                            window.currentSessionId = resultEvent.sessionId
                        }

                        let expectedPlaceholder = "pending-\(streamId.uuidString)"
                        if window.pendingPlaceholderIds.contains(expectedPlaceholder) {
                            if let idx = allSessionSummaries.firstIndex(where: { $0.id == expectedPlaceholder }) {
                                let old = allSessionSummaries[idx]
                                let replacement = ChatSession(
                                    id: resultEvent.sessionId,
                                    projectId: old.projectId,
                                    title: old.title,
                                    messages: [],
                                    createdAt: old.createdAt,
                                    updatedAt: old.createdAt,
                                    isPinned: old.isPinned,
                                    agentProvider: old.agentProvider,
                                    model: old.model,
                                    effort: old.effort,
                                    permissionMode: old.permissionMode,
                                    origin: old.origin,
                                    worktreePath: old.worktreePath,
                                    worktreeBranch: old.worktreeBranch,
                                    isArchived: old.isArchived,
                                    archivedAt: old.archivedAt
                                )
                                allSessionSummaries.removeAll { $0.id == expectedPlaceholder || $0.id == resultEvent.sessionId }
                                allSessionSummaries.insert(replacement.summary, at: 0)
                                threadStore.renameId(from: expectedPlaceholder, to: resultEvent.sessionId)
                                threadStore.upsert(replacement.summary, cliSessionId: resultEvent.sessionId)
                            } else {
                                allSessionSummaries.removeAll { $0.id == expectedPlaceholder }
                                threadStore.delete(id: expectedPlaceholder)
                            }
                            window.removePendingPlaceholder(expectedPlaceholder)
                        }

                        broadcastMobileSessionRedirect(from: previousSessionKey, to: resultEvent.sessionId)
                    }

                    // Record this provider's native session id (owner: on the
                    // renamed thread id; switched provider: on the stable thread
                    // id) so each provider can resume its own native session.
                    recordProviderSessionId(agentProvider, nativeId: resultEvent.sessionId, threadId: sessionKey)

                    // A background completion is "finished, unread". Setting the
                    // flag inside finalizeStreamSession means the trailing
                    // `.streamingFinished` broadcast already carries it to mobile.
                    let isFg = (window.currentSessionId ?? window.newSessionKey) == sessionKey
                    let markUnread = !isFg && !resultEvent.isError

                    let stopProject = projects.first(where: { $0.id == projectId })
                    // Capture queued-followup state now, synchronously, before
                    // `finalizeStreamSession` schedules the auto-flush that pops
                    // the next queued message. Stop hooks (review/commit) use this
                    // to defer until the queue has fully drained.
                    let hasQueuedFollowups = !threadStore.loadQueue(sessionKey: sessionKey).isEmpty

                    finalizeStreamSession(for: sessionKey) { state in
                        if let cost = resultEvent.totalCostUsd { state.costUsd = cost }
                        if let duration = resultEvent.durationMs { state.durationMs += duration }
                        if let turns = resultEvent.totalTurns { state.turns += turns }
                        if let usage = resultEvent.usage {
                            state.inputTokens += usage.inputTokens
                            state.outputTokens += usage.outputTokens
                            state.cacheCreationTokens += usage.cacheCreationInputTokens
                            state.cacheReadTokens += usage.cacheReadInputTokens
                        }
                        if markUnread { state.hasUncheckedCompletion = true }
                    }
                    let finalAssistantText = lastAssistantResponseText(in: stateForSession(sessionKey).messages)

                    // Release cross-thread MCP callers as soon as the model turn
                    // is finalized. Session-end hooks can run follow-up work and
                    // persist cards afterward, but they must not delay the
                    // `ide__send_to_thread` JSON-RPC response.
                    recordStreamCompletion(
                        streamId: streamId,
                        sessionId: sessionKey,
                        assistantText: finalAssistantText,
                        error: resultEvent.isError ? "Agent reported an error result." : nil
                    )

                    // Session-stop hooks fire when streaming stops. Before-stop
                    // runs *after* `finalizeStreamSession` so its status card lands
                    // after the finalized assistant message (not before it), and
                    // before `saveSession` below so the card persists ("passed to
                    // the session"). After-stop runs post-save (shown, not saved).
                    var stopHookFailureOutput: String?
                    if let stopProject, !stopHooksHandledStreamIds.contains(streamId) {
                        stopHooksHandledStreamIds.insert(streamId)
                        let stopResult = await hookManager.dispatchBeforeSessionEnd(SessionEndPayload(
                            project: stopProject,
                            sessionKey: sessionKey,
                            sessionId: resultEvent.sessionId,
                            reason: .completed,
                            turnDidError: resultEvent.isError,
                            lastAssistantText: finalAssistantText,
                            hasQueuedFollowups: hasQueuedFollowups
                        ))
                        if stopResult.hasError {
                            stopHookFailureOutput = stopResult.combinedOutput
                        } else {
                            // Hook passed — clear any prior auto-continue tally.
                            stopHookRepromptCounts[sessionKey] = nil
                        }
                    }

                    if isFg {
                        window.currentSessionId = sessionKey
                        if resultEvent.isError {
                            let errText = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)
                                ?? "\(agentProvider.displayNameText) returned an error."
                            addErrorMessage(errText, in: window)
                        }
                    }

                    await saveSession(
                        sessionId: sessionKey,
                        projectId: projectId,
                        messages: stateForSession(sessionKey).messages
                    )

                    if agentProvider == .claudeCode {
                        reconcileFromDisk(sessionId: resultEvent.sessionId, projectId: projectId, cwd: cwd)
                    }

                    // Whether this turn was the synthetic commit/push follow-up the
                    // Commit & Push hook injected. Captured BEFORE the after-stop
                    // dispatch below, which is where CommitPushHook consumes the
                    // marker. A hook-injected turn's last "user" message is the
                    // commit prompt, not the user's words — summarizing or
                    // extracting memories from it pollutes the briefing/memories
                    // with "Commit the changes from this session…" boilerplate.
                    let wasHookInjectedTurn = isSetupSession(
                        kind: HookSetupKind.commitPush,
                        sessionKey: sessionKey
                    ) || isSetupSession(
                        kind: HookSetupKind.sendMessage,
                        sessionKey: sessionKey
                    )

                    // After-session-stop hooks: shown only, not re-saved. This
                    // dispatch also drives the response-complete notification
                    // (ResponseNotificationHook), which self-suppresses unless
                    // the turn genuinely completed without error.
                    if let stopProject {
                        await hookManager.dispatchAfterSessionEnd(SessionEndPayload(
                            project: stopProject,
                            sessionKey: sessionKey,
                            sessionId: resultEvent.sessionId,
                            reason: .completed,
                            turnDidError: resultEvent.isError,
                            lastAssistantText: lastAssistantResponseText(in: stateForSession(sessionKey).messages),
                            hasQueuedFollowups: hasQueuedFollowups
                        ))
                    }

                    // A failing before-stop hook auto-continues the agent so it
                    // can fix the reported problem (e.g. lint). Skipped when the
                    // turn itself errored — re-prompting won't help there.
                    if let stopProject, let failureOutput = stopHookFailureOutput, !resultEvent.isError {
                        repromptAfterStopHookFailure(output: failureOutput, project: stopProject, sessionKey: sessionKey)
                    }

                    if !resultEvent.isError {
                        let sid = resultEvent.sessionId
                        let key = sessionKey
                        let cwdCapture = cwd
                        if agentProvider == .claudeCode {
                            Task { [weak self] in
                                guard let self else { return }
                                if let pct = await claude.fetchContextPercentage(sessionId: sid, cwd: cwdCapture) {
                                    updateState(key) { $0.lastTurnContextUsedPercentage = pct }
                                }
                            }
                        }

                        // The response-complete notification is posted by
                        // ResponseNotificationHook via the after-session-end
                        // dispatch above.

                        // Skip summary/memory updates for the hook-injected
                        // commit & push turn — its last user message is the
                        // commit prompt, not the user's, and would otherwise
                        // leak into the thread summary and extracted memories.
                        if !wasHookInjectedTurn {
                            scheduleThreadSummaryUpdate(
                                sessionId: sessionKey,
                                projectId: projectId,
                                cwd: cwd,
                                messages: stateForSession(sessionKey).messages
                            )
                            scheduleMemoryExtraction(
                                sessionId: sessionKey,
                                projectId: projectId,
                                messages: stateForSession(sessionKey).messages
                            )
                        }

                        // If this session is running in the background, automatically process any queued messages.
                        // Foreground sessions are handled by InputBarView via isStreaming onChange.
                        if !isFg {
                            await processBackgroundQueue(for: sessionKey, projectId: projectId, cwd: cwd, in: window)
                        }
                    }

                case .rateLimitEvent(let info):
                    logger.warning("[Stream:UI] event #\(eventCount) .rateLimitEvent (retrySec=\(info.retrySec ?? 0))")
                    if (window.currentSessionId ?? window.newSessionKey) == sessionKey,
                       let retry = info.retrySec, retry > 0
                    {
                        addErrorMessage("Rate limited. Retrying in \(Int(retry))s...", in: window)
                    }

                case .todoSnapshot(let snapshot):
                    let targetSession = snapshot.sessionId ?? sessionKey
                    let done = snapshot.items.filter { $0.status == .completed }.count
                    let active = snapshot.items.first(where: { $0.status == .inProgress })?.activeForm ?? "-"
                    logger.info(
                        "[TodoSnapshot] session=\(targetSession, privacy: .public) total=\(snapshot.items.count) done=\(done) active=\(active, privacy: .public)"
                    )
                    threadStore.upsertTodoSnapshot(sessionId: targetSession, items: snapshot.items)
                    todoSnapshotsRevision &+= 1
                    broadcastMobileSessionStatus(sessionID: targetSession)

                case .acpModelsDiscovered(let event):
                    logger.info("[Stream:UI] event #\(eventCount) .acpModelsDiscovered clientId=\(event.clientId, privacy: .public) configId=\(event.config.configId, privacy: .public) models=\(event.config.options.count) [\(Self.acpModelListDescription(event.config.options), privacy: .public)]")
                    applyDiscoveredACPModels(clientId: event.clientId, config: event.config)

                case .unknown(let raw):
                    if eventCount <= 5 || eventCount % 100 == 0 {
                        logger.debug("[Stream:UI] event #\(eventCount) .unknown (gap=\(String(format: "%.1f", gap))s, len=\(raw.count))")
                    }
                    handlePartialEvent(raw, for: sessionKey)
                    recordStreamPartialResponseIfNeeded(streamId: streamId, sessionId: sessionKey)
                }
            }

            let elapsed = Date().timeIntervalSince(streamStart)
            logger.info("[Stream:UI] stream ended after \(eventCount) events, \(String(format: "%.1f", elapsed))s total")
            if let debugLogPrefix {
                logger.info("\(debugLogPrefix, privacy: .public) phase=streamEnded stream=\(streamId) eventCount=\(eventCount, privacy: .public) total=\(String(format: "%.2f", elapsed), privacy: .public)s")
            }

            // Consume any remaining stderr — used as error message content below.
            // If already consumed at result.isError time, this returns nil.
            let stderrOutput = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)

            if eventCount == 0 {
                // User cancellation revokes activeStreamId or cancels the task — distinguish
                // that from a real "CLI died with no output" failure.
                let wasCancelled = Task.isCancelled || stateForSession(sessionKey).activeStreamId != streamId
                if !wasCancelled {
                    let errorMsg = stderrOutput ?? "No response received"
                    addErrorMessage(errorMsg, in: window)
                    logger.error("[Stream:UI] no events received — appending error bubble. stderr=\(stderrOutput ?? "nil")")
                } else {
                    logger.debug("[Stream:UI] no events received — suppressed (cancelled). stderr=\(stderrOutput ?? "nil")")
                }
            }

            let isStillOwner = stateForSession(sessionKey).activeStreamId == streamId
            let stillStreaming = stateForSession(sessionKey).isStreaming
            if stillStreaming, isStillOwner {
                logger.warning("[Stream:UI] isStreaming was still true at stream end — forcing cleanup")
                let markUnread = (window.currentSessionId ?? window.newSessionKey) != sessionKey
                finalizeStreamSession(for: sessionKey) { state in
                    if markUnread { state.hasUncheckedCompletion = true }
                }

                // If the last assistant message is invisible after cleanup (blocks=[] because
                // all tool calls had empty/nil results), show an error bubble so the user
                // understands what happened rather than seeing no response at all.
                let lastMsg = stateForSession(sessionKey).messages.last
                if lastMsg.map({ $0.role == .assistant && $0.blocks.isEmpty }) == true {
                    let errorMsg = stderrOutput ?? "Response was interrupted"
                    updateState(sessionKey) { state in
                        state.messages.append(ChatMessage(role: .assistant, content: errorMsg, isError: true))
                    }
                }

                let msgs = stateForSession(sessionKey).messages
                if !msgs.isEmpty {
                    await saveSession(sessionId: sessionKey, projectId: projectId, messages: msgs)
                }
            } else if stillStreaming, !isStillOwner {
                let currentOwner = stateForSession(sessionKey).activeStreamId
                if currentOwner == nil {
                    logger.warning("[Stream:UI] stream \(streamId) ended — no active owner for session, forcing cleanup")
                    finalizeStreamSession(for: sessionKey)
                    let msgs = stateForSession(sessionKey).messages
                    if !msgs.isEmpty {
                        await saveSession(sessionId: sessionKey, projectId: projectId, messages: msgs)
                    }
                } else {
                    logger.info("[Stream:UI] stream \(streamId) ended but newer stream \(currentOwner!) owns session — skipping cleanup")
                }
            }

            // Fallback completion record: covers cancellations, no-events errors,
            // and any path where `.result` was not received. The `.result` case
            // already records a completion before reaching here — recordStreamCompletion
            // is idempotent (it overwrites with the latest), but if a prior call set a
            // successful completion we don't want to clobber it with an error.
            if !recordedStreamCompletionIds.contains(streamId) {
                let assistantText = lastAssistantResponseText(in: stateForSession(sessionKey).messages)
                let errorMsg: String? = eventCount == 0
                    ? (stderrOutput ?? "Stream ended with no events.")
                    : (Task.isCancelled ? "Stream was cancelled." : nil)
                recordStreamCompletion(
                    streamId: streamId,
                    sessionId: sessionKey,
                    assistantText: assistantText,
                    error: errorMsg
                )
            }
            recordedStreamCompletionIds.remove(streamId)
            streamPartialResponseDeliveredIds.remove(streamId)
            streamDebugLogPrefixes.removeValue(forKey: streamId)
        }
    }

}
