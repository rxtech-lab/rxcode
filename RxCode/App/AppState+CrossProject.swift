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
        includePriorContext: Bool = true,
        history: [ChatMessage] = [],
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
        // Measures how much of the provider's usage limits each finished
        // span on this stream consumed.
        var rateLimitMeasurement = beginRateLimitMeasurement(for: agentProvider)
        defer { endRateLimitMeasurement(rateLimitMeasurement) }

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
            effort: effort,
            permissionMode: permissionMode,
            registerMode: registerMode,
            projectId: projectId,
            includeIDEMCP: includeIDEMCP,
            includePriorContext: includePriorContext,
            streamStart: streamStart
        )

        var analyticsModel = preflight.resolvedModel ?? model
        defer {
            let finalKey = sessionKey
            let endedAt = Date()
            let limits = codingAnalyticsLimits(provider: agentProvider, model: analyticsModel,
                clientID: preflight.acpSpec?.id, phase: .end, now: endedAt)
            Task { await CodingAnalyticsRecorder.shared.finish(turnID: streamId, threadID: finalKey, now: endedAt, usageLimits: limits) }
        }

        let stream: AsyncStream<StreamEvent>
        if let earlyStream = preflight.earlyStream {
            stream = earlyStream
        } else {
            await recordThreadCheckout(sessionId: sessionKey, projectId: projectId, cwd: cwd, streamId: streamId)
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
                effort: preflight.resolvedEffort,
                permissionMode: preflight.resolvedSendMode,
                planMode: permissionMode == .plan,
                hookSettingsPath: hookSettingsPath,
                mcpClaudeConfigPath: preflight.mcpClaudeConfigPath,
                extraSystemPrompt: preflight.extraSystemPrompt,
                mcpCodexOverrides: preflight.mcpCodexOverrides,
                acpMCPServers: preflight.acpMCPServers,
                acpSpec: preflight.acpSpec,
                clientSessionKey: sessionKey,
                mcpServers: preflight.mcpRecords,
                ideBridgeCommand: preflight.ideBridgeCommand,
                history: history
            )
            stream = await backend(for: agentProvider).send(request)
            let backendReturnedElapsed = Date().timeIntervalSince(streamStart)
            logger.info("[Stream:UI] backend send returned provider=\(agentProvider.rawValue, privacy: .public) stream=\(streamId) after=\(String(format: "%.2f", backendReturnedElapsed), privacy: .public)s")
            if let debugLogPrefix {
                logger.info("\(debugLogPrefix, privacy: .public) phase=backendSendReturned stream=\(streamId) after=\(String(format: "%.2f", backendReturnedElapsed), privacy: .public)s provider=\(agentProvider.rawValue, privacy: .public)")
            }
        }

        let tracksEdits = agentProvider.staticCapabilities.contains(.fileEdit)
        if tracksEdits {
            shellTrackerBeginStream(streamId: streamId, sessionKey: sessionKey, cwd: cwd, agentProvider: agentProvider)
        }
        defer {
            if tracksEdits { shellTrackerEndStream(streamId: streamId, sessionKey: sessionKey, cwd: cwd) }
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
            projectID: projectId,
            in: window
        )
        defer { watchdogTask.cancel() }

        // Resume keeps the previous assistant messages after the same user request.
        // Only text produced by this stream can duplicate a consolidated response.
        let priorMessages = stateForSession(sessionKey).messages
        let firstResponseIndex = priorMessages.count - (priorMessages.last?.isStreaming == true ? 1 : 0)
        var eventCount = 0
        var reportedError: String?
        var lastEventTime = Date()
        // Start of the span the next `result` accounts for in the persisted
        // usage stats; advanced on each result so background follow-up
        // results on the same stream are not double counted.
        var usageSpanStart = streamStart
        let fallbackUsageModel = preflight.resolvedModel ?? model
        func usageModel(_ key: String) -> String? {
            stateForSession(key).activeModelName ?? fallbackUsageModel
        }
        // The CLI reads stdin in order, so the first replayed user frame is
        // this turn's own prompt; every later one is a steer being taken.
        var sawPromptReplay = false
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

                if case .result(let result) = event {
                    await CodingAnalyticsRecorder.shared.update(
                        turnID: streamId, model: analyticsModel, usage: result.usage,
                        usageLimits: codingAnalyticsLimits(provider: agentProvider, model: analyticsModel,
                            clientID: preflight.acpSpec?.id, phase: .result)
                    )
                }

                let ownsSession = stateForSession(sessionKey).activeStreamId == streamId

                if !ownsSession {
                    if case .result(let resultEvent) = event {
                        logger.info("[Stream:UI] event #\(eventCount) .result received after losing ownership")
                        recordUsageStats(
                            resultEvent: resultEvent,
                            since: usageSpanStart,
                            agentProvider: agentProvider,
                            model: usageModel(sessionKey),
                            projectId: projectId
                        )
                        recordRateLimitTaskCost(
                            &rateLimitMeasurement,
                            model: usageModel(sessionKey),
                            projectId: projectId,
                            threadId: sessionKey,
                            prompt: prompt,
                            tokens: Self.rateLimitTaskTokens(resultEvent.usage),
                            startedAt: usageSpanStart
                        )
                        usageSpanStart = Date()
                        await finalizeAgentStream(agentProvider: agentProvider, streamId: streamId)
                        // A late result belongs to the old turn. Its successor owns
                        // the thread identity, transcript, and recovery checkpoint.
                    } else {
                        logger.debug("[Stream:UI] event #\(eventCount) — stream \(streamId) no longer owns session \(sessionKey), skipping")
                    }
                    continue
                }

                defer { scheduleTurnCheckpoint(sessionID: sessionKey, streamID: streamId) }
                switch event {
                case .system(let systemEvent):
                    logger.info("[Stream:UI] event #\(eventCount) .system (gap=\(String(format: "%.1f", gap))s)")
                    if let model = systemEvent.model {
                        analyticsModel = model
                        updateState(sessionKey) { $0.activeModelName = model }
                        await CodingAnalyticsRecorder.shared.update(turnID: streamId, model: model)
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
                            if sessionKey != sid {
                                promoteStreamingThread(from: sessionKey, to: sid, cwd: cwd, in: window)
                                sessionKey = sid
                                startFlushTimer(for: sid)
                            }
                        }
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

                    var assistantToolUses: [(String, String, [String: JSONValue])] = []
                    updateState(sessionKey) { state in
                        // Text fallback: only buffer text when no text_delta has been received in
                        // this turn. Normally content_block_delta(text_delta) is the primary path.
                        let canBufferText: Bool = {
                            guard state.textDeltaBuffer.isEmpty else { return false }
                            let afterLastUser = (state.messages.lastIndex(where: { $0.role == .user }).map { $0 + 1 }) ?? 0
                            return !state.messages.dropFirst(max(afterLastUser, firstResponseIndex)).contains {
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
                                    assistantToolUses.append((id, name, merged))
                                } else {
                                    if state.needsNewMessage {
                                        if let idx = state.messages.indices.reversed().first(where: {
                                            state.messages[$0].role == .assistant && state.messages[$0].isStreaming
                                        }) {
                                            state.messages[idx].isStreaming = false
                                            state.messages[idx].finalizeToolCalls(dropIncomplete: false)
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
                                    assistantToolUses.append((id, name, input))
                                }
                            case .thinking:
                                state.isThinking = true
                            }
                        }
                    }
                    for (id, name, input) in assistantToolUses {
                        shellTrackerUpsertToolSpan(id: id, name: name, input: input, sessionKey: sessionKey)
                    }
                    recordStreamPartialResponseIfNeeded(streamId: streamId, sessionId: sessionKey)

                case .user(let userMessage):
                    logger.debug("[Stream:UI] event #\(eventCount) .user (gap=\(String(format: "%.1f", gap))s, toolUseId=\(userMessage.toolUseId ?? "none"))")
                    if userMessage.isReplay {
                        if sawPromptReplay {
                            updateState(sessionKey) { $0.unconsumedSteerCount = max(0, $0.unconsumedSteerCount - 1) }
                        }
                        sawPromptReplay = true
                        break
                    }
                    if userMessage.toolUseId == nil, userMessage.isError, !userMessage.content.isEmpty {
                        reportedError = userMessage.content
                    }
                    updateState(sessionKey) { state in
                        guard let toolUseId = userMessage.toolUseId else { return }
                        state.pendingToolResults.append((toolUseId, userMessage.content, userMessage.isError))
                        state.needsNewMessage = true
                    }

                case .computerUseWindows(let windows):
                    updateState(sessionKey) { state in
                        for window in windows {
                            if let index = state.computerUseWindows.firstIndex(where: { $0.id == window.id }) {
                                state.computerUseWindows[index] = state.computerUseWindows[index].updated(with: window)
                            } else {
                                // Newest app first so the window being driven stays visible.
                                state.computerUseWindows.insert(window, at: 0)
                            }
                        }
                    }

                case .result(let resultEvent):
                    if let percentage = resultEvent.contextWindow?.usedPercentage, percentage.isFinite {
                        updateState(sessionKey) { $0.lastTurnContextUsedPercentage = max(0, min(100, percentage)) }
                    }
                    logger.info("[Stream:UI] event #\(eventCount) .result (gap=\(String(format: "%.1f", gap))s, isError=\(resultEvent.isError), session=\(resultEvent.sessionId))")
                    if let debugLogPrefix {
                        let totalElapsed = Date().timeIntervalSince(streamStart)
                        logger.info("\(debugLogPrefix, privacy: .public) phase=resultEvent stream=\(streamId) eventCount=\(eventCount, privacy: .public) total=\(String(format: "%.2f", totalElapsed), privacy: .public)s gap=\(String(format: "%.1f", gap), privacy: .public)s isError=\(resultEvent.isError, privacy: .public) session=\(resultEvent.sessionId, privacy: .public)")
                    }
                    recordUsageStats(
                        resultEvent: resultEvent,
                        since: usageSpanStart,
                        agentProvider: agentProvider,
                        model: usageModel(sessionKey),
                        projectId: projectId
                    )
                    recordRateLimitTaskCost(
                        &rateLimitMeasurement,
                        model: usageModel(sessionKey),
                        projectId: projectId,
                        threadId: sessionKey,
                        prompt: prompt,
                        tokens: Self.rateLimitTaskTokens(resultEvent.usage),
                        startedAt: usageSpanStart
                    )
                    usageSpanStart = Date()

                    sessionKey = await handleStreamResult(
                        resultEvent, sessionKey: sessionKey, streamId: streamId, agentProvider: agentProvider,
                        projectId: projectId, cwd: cwd, eventCount: eventCount, reportedError: reportedError, in: window
                    )

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
                    recordTodoSnapshot(snapshot.items, forSessionId: targetSession)
                    broadcastMobileSessionStatus(sessionID: targetSession)

                case .acpModelsDiscovered(let event):
                    logger.info("[Stream:UI] event #\(eventCount) .acpModelsDiscovered clientId=\(event.clientId, privacy: .public) configId=\(event.config.configId, privacy: .public) models=\(event.config.options.count) [\(Self.acpModelListDescription(event.config.options), privacy: .public)]")
                    applyDiscoveredACPModels(clientId: event.clientId, config: event.config)

                // The four cases below are the decoded equivalents of the raw
                // `content_block_*` frames that arrive as `.unknown`. Backends
                // built on RxAgentSDK emit these directly; both paths converge
                // on the same `apply…` helpers in `AppState+Stream.swift`.
                case .textDelta(let text):
                    applyTextDelta(text, for: sessionKey)
                    recordStreamPartialResponseIfNeeded(streamId: streamId, sessionId: sessionKey)

                case .thinkingDelta:
                    applyThinkingDelta(for: sessionKey)

                case .toolCallStarted(let id, let name):
                    logger.debug("[Stream:UI] event #\(eventCount) .toolCallStarted \(name, privacy: .public) id=\(id, privacy: .public)")
                    beginToolCall(id: id, name: name, for: sessionKey)

                case .toolCallInput(let id, let input):
                    applyToolCallInput(id: id, input: input, for: sessionKey)
                    recordStreamPartialResponseIfNeeded(streamId: streamId, sessionId: sessionKey)

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

            let stillOwnsTurn = stateForSession(sessionKey).activeStreamId == streamId
            let interrupted = stillOwnsTurn && stateForSession(sessionKey).isStreaming && !Task.isCancelled
            if interrupted {
                let message = reportedError ?? stderrOutput ?? (eventCount == 0 ? "No response received" : "Response was interrupted")
                await interruptStream(sessionID: sessionKey, streamID: streamId, projectID: projectId, message: message)
            }

            // Fallback completion record: covers cancellations, no-events errors,
            // and any path where `.result` was not received. The `.result` case
            // already records a completion before reaching here — recordStreamCompletion
            // is idempotent (it overwrites with the latest), but if a prior call set a
            // successful completion we don't want to clobber it with an error.
            if !recordedStreamCompletionIds.contains(streamId) {
                let assistantText = lastAssistantResponseText(in: stateForSession(sessionKey).messages)
                let errorMsg: String? = interrupted ? (stderrOutput ?? "Response was interrupted") : eventCount == 0
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
