import Foundation
import os
import RxCodeCore

extension AppState {
    func handleStreamResult(
        _ resultEvent: ResultEvent, sessionKey initialSessionKey: String, streamId: UUID,
        agentProvider: AgentProvider, projectId: UUID, cwd: String, eventCount: Int, reportedError: String? = nil,
        turnMode: PermissionMode, includeIDEMCP: Bool, in window: WindowState
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

        guard stateForSession(sessionKey).activeStreamId == streamId else { return sessionKey }

        // Only the provider that owns the thread id may re-home the
        // thread. A switched provider's differing native id is recorded
        // (below) but must not rename the thread.
        let resultOwnsThreadId = window.pendingPlaceholderIds.contains("pending-\(streamId.uuidString)")
            || providerOwnsThreadId(agentProvider, threadId: sessionKey)
        // A turn that failed before the agent opened a session
        // reports an empty id; keep the thread on its current key.
        if !resultEvent.sessionId.isEmpty, sessionKey != resultEvent.sessionId && resultOwnsThreadId {
            promoteStreamingThread(from: sessionKey, to: resultEvent.sessionId, cwd: cwd, in: window)
            sessionKey = resultEvent.sessionId
        }

        // Record this provider's native session id (owner: on the
        // renamed thread id; switched provider: on the stable thread
        // id) so each provider can resume its own native session.
        recordProviderSessionId(agentProvider, nativeId: resultEvent.sessionId, threadId: sessionKey)

        let isFg = (window.currentSessionId ?? window.newSessionKey) == sessionKey

        let stopProject = projects.first(where: { $0.id == projectId })
        // Capture queued-followup state now, synchronously, before
        // `finalizeStreamSession` schedules the auto-flush that pops
        // the next queued message. Stop hooks (review/commit) use this
        // to defer until the queue has fully drained.
        let hasQueuedFollowups = !threadStore.loadQueue(sessionKey: sessionKey).isEmpty

        var failureText: String?
        if resultEvent.isError {
            let errText = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)
                ?? reportedError ?? "\(agentProvider.displayNameText) returned an error."
            guard stateForSession(sessionKey).activeStreamId == streamId else { return sessionKey }
            flushPendingUpdates(for: sessionKey, forceText: true)
            failureText = stateForSession(sessionKey).messages.suffix(2).map(\.content).joined(separator: "\n") + "\n" + errText
            updateState(sessionKey) { $0.messages.append(ChatMessage(role: .assistant, content: errText, isError: true)) }
            await checkpointTurn(sessionID: sessionKey, streamID: streamId)
            guard stateForSession(sessionKey).activeStreamId == streamId else { return sessionKey }
        }

        let reviewedUserMessage = stateForSession(sessionKey).messages.last(where: { $0.role == .user })?.id
        finalizeStreamSession(for: sessionKey, trackUnreadCompletion: !resultEvent.isError, interrupted: resultEvent.isError) { state in
            state.todoContinuationSource = streamId
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

        if !resultEvent.isError, !hasQueuedFollowups, !wasHookInjectedTurn, turnMode != .plan,
           let project = sessionProject(id: projectId),
           !hookController.threadSkipsHooks(sessionId: sessionKey),
           !sessionEndHooksSuppressed(sessionKey: sessionKey, sessionId: sessionKey),
           await continueUnfinishedTodos(sessionKey: sessionKey, streamId: streamId, project: project,
                                         turnMode: turnMode, includeIDEMCP: includeIDEMCP, reply: finalAssistantText) {
            return sessionKey
        }

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

        if let failureText, stateForSession(sessionKey).latestTurnID == streamId {
            scheduleUsageLimitResume(error: failureText, sessionKey: sessionKey, provider: agentProvider, projectId: projectId)
        }

        await saveSession(
            sessionId: sessionKey,
            projectId: projectId,
            messages: stateForSession(sessionKey).messages
        )

        if agentProvider == .claudeCode, !resultEvent.isError {
            reconcileFromDisk(sessionId: resultEvent.sessionId, projectId: projectId, cwd: cwd)
        }

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
        if let stopProject, let reviewedUserMessage, threadStore.fetch(id: sessionKey)?.implementationPlanID != nil,
           !resultEvent.isError, stopHookFailureOutput == nil, !hasQueuedFollowups {
            Task {
                await reviewFinishedImplementation(threadID: sessionKey, project: stopProject, cwd: cwd,
                                                   implementation: finalAssistantText, userMessageID: reviewedUserMessage)
            }
        }
        return sessionKey
    }

    private func continueUnfinishedTodos(sessionKey: String, streamId: UUID, project: Project,
                                         turnMode: PermissionMode, includeIDEMCP: Bool, reply: String) async -> Bool {
        guard let state = sessionStates[sessionKey], state.todoContinuationSource == streamId else { return false }
        let transcript = await Self.transcriptTodos(state.messages)
        let recorded = threadStore.fetchTodoSnapshot(sessionId: sessionKey)?.list
        let items = TodoListSnapshot.latest(transcript: transcript, recorded: recorded)?.items ?? []
        var continuation = state.todoContinuation
        guard let prompt = continuation.nextPrompt(items: items, reply: reply),
              sessionStates[sessionKey]?.todoContinuationSource == streamId else { return false }

        await saveSession(sessionId: sessionKey, projectId: project.id, messages: stateForSession(sessionKey).messages)
        guard !Task.isCancelled, let current = sessionStates[sessionKey],
              current.todoContinuationSource == streamId, !current.isStreaming,
              !current.messages.isEmpty, !current.planMode,
              threadStore.loadQueue(sessionKey: sessionKey).isEmpty else { return false }

        sessionStates[sessionKey]?.todoContinuation = continuation
        let card = hookController.insertCard(sessionKey: sessionKey, toolName: ToolCall.autoContinueToolName,
                                             input: ["summary": .string("Continuing unfinished todos")])
        hookController.completeCard(card, sessionKey: sessionKey, result: prompt, isError: false)
        let window = WindowState()
        window.currentSessionId = sessionKey
        window.selectedProject = project
        window.sessionPermissionMode = current.permissionMode ?? turnMode
        window.sessionEffort = current.effort
        return await sendPrompt(prompt, skipAppendingUserMessage: true, isStopHookReprompt: true,
                                includeIDEMCP: includeIDEMCP, in: window) != nil
    }

    @concurrent
    private static func transcriptTodos(_ messages: [ChatMessage]) async -> TodoListSnapshot? {
        TodoExtractor.latestSnapshot(in: messages)
    }
}
