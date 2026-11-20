import Foundation
import os
import RxCodeCore

extension AppState {
    func handleStreamResult(
        _ resultEvent: ResultEvent, sessionKey initialSessionKey: String, streamId: UUID,
        agentProvider: AgentProvider, projectId: UUID, cwd: String, eventCount: Int, in window: WindowState
    ) async -> String {
        var sessionKey = initialSessionKey
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
        //
        // A steer the CLI has not taken yet is the same shape: it
        // arrived after the turn's last tool call, so the CLI runs
        // it as its own turn after this `result`. Tearing down here
        // would kill that turn, leaving the steer unanswered and the
        // session-end hooks judging a turn that never saw it.
        let pendingSteers = agentProvider == .claudeCode
            ? stateForSession(sessionKey).unconsumedSteerCount
            : 0
        if !stateForSession(sessionKey).liveBackgroundTaskIds.isEmpty || pendingSteers > 0 {
            let live = stateForSession(sessionKey).liveBackgroundTaskIds.count
            logger.info("[Stream:UI] event #\(eventCount) .result yields with \(live) live background task(s), \(pendingSteers) pending steer(s); keeping turn in progress (origin=\(resultEvent.originKind ?? "none", privacy: .public))")
            // This turn is over; commit its text so the steered
            // turn's reply opens its own bubble after it.
            if pendingSteers > 0 {
                flushPendingUpdates(for: sessionKey, forceText: true)
            }
            updateState(sessionKey) { state in
                if pendingSteers > 0 { state.needsNewMessage = true }
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
            return sessionKey
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
        // A turn that failed before the agent opened a session
        // reports an empty id; keep the thread on its current key.
        if !resultEvent.sessionId.isEmpty, sessionKey != resultEvent.sessionId && resultOwnsThreadId {
            let previousSessionKey = sessionKey
            let wasForeground = (window.currentSessionId ?? window.newSessionKey) == previousSessionKey
            if let state = sessionStates.removeValue(forKey: previousSessionKey) {
                sessionStates[resultEvent.sessionId] = state
            }
            renameDraftState(from: previousSessionKey, to: resultEvent.sessionId, in: window)
            applySessionIdRedirect(from: previousSessionKey, to: resultEvent.sessionId)
            shellTrackerRenameSession(from: previousSessionKey, to: resultEvent.sessionId, cwd: cwd)
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
                    renameThreadFileEdits(from: expectedPlaceholder, to: resultEvent.sessionId)
                    threadStore.upsert(replacement.summary, cliSessionId: resultEvent.sessionId)
                } else {
                    allSessionSummaries.removeAll { $0.id == expectedPlaceholder }
                    threadStore.delete(id: expectedPlaceholder)
                    removeThreadFileEditsFromIndex([expectedPlaceholder])
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
        await awaitPendingShellDetections(for: sessionKey)
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
                hasQueuedFollowups: hasQueuedFollowups,
                deliveryID: streamId.uuidString
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
        }
        if resultEvent.isError {
            let errText = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)
                ?? "\(agentProvider.displayNameText) returned an error."
            let failureText = stateForSession(sessionKey).messages.suffix(2).map(\.content).joined(separator: "\n") + "\n" + errText
            updateState(sessionKey) { state in
                state.messages.append(ChatMessage(role: .assistant, content: errText, isError: true))
            }
            scheduleUsageLimitResume(error: failureText, sessionKey: sessionKey, provider: agentProvider, projectId: projectId)
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
            _ = await hookManager.dispatchAfterSessionEnd(SessionEndPayload(
                project: stopProject,
                sessionKey: sessionKey,
                sessionId: resultEvent.sessionId,
                reason: .completed,
                turnDidError: resultEvent.isError,
                lastAssistantText: lastAssistantResponseText(in: stateForSession(sessionKey).messages),
                hasQueuedFollowups: hasQueuedFollowups,
                deliveryID: streamId.uuidString
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
        return sessionKey
    }
}
