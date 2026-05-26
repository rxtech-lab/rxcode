import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

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
        timeoutSeconds: TimeInterval = 120
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
        // pending-) key the stream is bound to. The CLI may rename it to its
        // own sid mid-stream; we surface whichever id the completion lands on.
        let postSendThreadId = window.currentSessionId ?? resolvedThreadId ?? ""

        if !waitForResponse {
            // Don't leak the result in the dictionary — the caller is
            // fire-and-forget. Drop it once it lands.
            Task { [weak self] in
                _ = await self?.awaitStreamCompletion(streamId: streamId, timeout: timeoutSeconds)
            }
            return CrossProjectSendResult(
                threadId: postSendThreadId,
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
                threadId: window.currentSessionId ?? postSendThreadId,
                projectId: resolvedProject.id,
                done: false,
                assistantText: partial,
                error: nil
            )
        }
    }

    /// Drop "No response requested." text blocks from the assistant message
    /// at `idx`. If the message has no blocks left after the strip, remove
    /// it entirely. Called at turn-finalization sites — the marker is the
    /// model's response when a turn arrives without a user prompt
    /// (ScheduleWakeup, hook re-entry) and reads as noise in the chat UI.
    /// Strip CLI no-op meta text ("no response requested") from a message.
    ///
    /// `removeIfEmpty` controls whether a message left with no blocks is also
    /// deleted. The normal stream path passes `true` to discard pure no-op
    /// envelopes; the cancel path passes `false` so pausing a turn never makes
    /// the partial assistant bubble disappear.
    static func stripNoOpText(at idx: Int, in messages: inout [ChatMessage], removeIfEmpty: Bool = true) {
        guard messages.indices.contains(idx) else { return }
        messages[idx].blocks.removeAll { block in
            guard let text = block.text else { return false }
            return CLIMetaEnvelope.isNoResponseRequested(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if removeIfEmpty, messages[idx].blocks.isEmpty {
            messages.remove(at: idx)
        }
    }

    /// Wrap a branch briefing into a system-prompt section the agent can use as
    /// background context. The briefing is auto-generated from earlier threads,
    /// so it is framed as advisory rather than authoritative.
    static func branchBriefingSystemPrompt(branch: String, briefing: String) -> String {
        let trimmed = briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        # Current branch briefing

        The notes below are an accumulated briefing of recent work on this \
        project's current branch (`\(branch)`). They are auto-generated from \
        previous chat threads — treat them as background context for the user's \
        request, and be aware they may be incomplete or slightly out of date.

        \(trimmed)
        """
    }

    static func promptWithBackgroundContext(_ contexts: [String], prompt: String) -> String {
        let context = contexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !context.isEmpty else { return prompt }
        return """
        \(context)

        User request:
        \(prompt)
        """
    }

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
        window: WindowState
    ) async {
        // Mode used when registering a session with PermissionServer for hook auto-approve.
        // When plan toggle is on, `permissionMode` is `.plan` (for the CLI flag) but the
        // user's dropdown choice (e.g. `.auto`) should still drive the hook policy.
        let registerMode = hookSessionMode ?? permissionMode
        let streamStart = Date()
        logger.info("[Stream:UI] starting processStream (cli=\(cliSessionId ?? "new"), key=\(internalSessionKey))")

        var sessionKey = internalSessionKey

        // Resolve per-backend send-request fields (MCP injection, ACP client
        // spec, model split) before dispatching through the unified protocol.
        var mcpClaudeConfigPath: String? = nil
        var extraSystemPrompt: String? = nil
        var mcpCodexOverrides: [String] = []
        var acpMCPServers: [JSONValue] = []
        var acpSpec: ACPClientSpec? = nil
        var resolvedPrompt = prompt
        var resolvedModel: String? = model
        var resolvedSendMode: PermissionMode = permissionMode
        var earlyStream: AsyncStream<StreamEvent>? = nil

        func appendExtraSystemPrompt(_ context: String) {
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let existing = extraSystemPrompt, !existing.isEmpty {
                extraSystemPrompt = "\(existing)\n\n\(trimmed)"
            } else {
                extraSystemPrompt = trimmed
            }
        }

        let resolvedMemoryContext: String
        if memoryEnabled, memoryInjectEnabled {
            let systemItems = await systemPromptMemoryItems(projectId: projectId, provider: agentProvider, model: model)
            let hits = await memoryService.search(prompt, projectId: projectId, limit: memoryMaxContextItems)
            resolvedMemoryContext = memoryContextSystemPrompt(systemItems: systemItems, relatedHits: hits)
        } else {
            resolvedMemoryContext = ""
        }

        let branchBriefingContext: String
        if let branch = await GitHelper.currentBranch(at: cwd),
           let briefing = threadStore.branchBriefingItem(projectId: projectId, branch: branch) {
            branchBriefingContext = Self.branchBriefingSystemPrompt(
                branch: branch,
                briefing: briefing.briefing
            )
        } else {
            branchBriefingContext = ""
        }

        switch agentProvider {
        case .claudeCode:
            // Allocate a per-session IDE-MCP port so the Claude agent can call
            // IDE-only tools — cross-project chat (`ide__send_to_thread`),
            // thread history, running jobs, usage. The bridge is a perl
            // one-liner Claude runs as the `rxcode-ide` MCP server child.
            let idePort = await ideMCPServer.allocate(
                sessionKey: sessionKey,
                capabilities: AgentProvider.claudeCode.staticCapabilities
            )
            let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
            mcpClaudeConfigPath = await mcp.writeClaudeConfig(projectPath: cwd, bridgeCommand: bridge)
            // Surface the accumulated briefing for the project's current branch
            // to the agent as background context via `--append-system-prompt`.
            appendExtraSystemPrompt(branchBriefingContext)
            appendExtraSystemPrompt(resolvedMemoryContext)
            if let skillContext = await marketplace.promptContext(for: .claudeCode) {
                appendExtraSystemPrompt(skillContext)
            }
        case .codex:
            // Allocate a per-session IDE-MCP port so the Codex agent can call
            // IDE-only tools — cross-project chat, thread history, running
            // jobs, usage, durable memory. The bridge is a perl one-liner
            // Codex runs as the `rxcode-ide` stdio MCP server child.
            let idePort = await ideMCPServer.allocate(
                sessionKey: sessionKey,
                capabilities: AgentProvider.codex.staticCapabilities
            )
            let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
            mcpCodexOverrides = await mcp.codexConfigOverrides(projectPath: cwd, bridgeCommand: bridge)
            mcpCodexOverrides += await marketplace.codexConfigOverrides()
            resolvedPrompt = Self.promptWithBackgroundContext(
                [branchBriefingContext, resolvedMemoryContext],
                prompt: resolvedPrompt
            )
            if let skillContext = await marketplace.promptContext(for: .codex) {
                resolvedPrompt = "\(skillContext)\n\nUser request:\n\(resolvedPrompt)"
            }
            resolvedSendMode = registerMode
        case .acp:
            // Allocate a per-session IDE-MCP port so the ACP agent can call
            // polyfill / introspection tools. The agent's MCP child is a
            // perl one-liner that bridges its stdio to our TCP listener;
            // the listener stays bound to this session for its lifetime.
            let idePort = await ideMCPServer.allocate(
                sessionKey: sessionKey,
                capabilities: AgentProvider.acp.staticCapabilities
            )
            let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
            acpMCPServers = await mcp.acpMCPServers(
                projectPath: cwd,
                bridgeCommand: bridge
            )
            resolvedPrompt = Self.promptWithBackgroundContext(
                [branchBriefingContext, resolvedMemoryContext],
                prompt: resolvedPrompt
            )
            if let skillContext = await marketplace.promptContext(for: .acp) {
                resolvedPrompt = "\(skillContext)\n\nUser request:\n\(resolvedPrompt)"
            }
            // `model` may be a composite `<clientId>::<model>` key (from the picker)
            // or a bare model id (from a per-session override).
            let split = acpSelectionParts(for: model)
            let resolvedClientId = split?.clientId
                ?? sessionStates[sessionKey]?.acpClientId
                ?? selectedACPClientId
            resolvedModel = split?.model ?? model
            resolvedSendMode = registerMode
            if let spec = acpClients.first(where: { $0.id == resolvedClientId && $0.enabled }) {
                acpSpec = spec
            } else {
                logger.error("[ACP] no enabled client for id=\(resolvedClientId, privacy: .public)")
                earlyStream = AsyncStream<StreamEvent> { c in
                    c.yield(.user(UserMessage(
                        toolUseId: nil,
                        content: "No ACP client configured. Add one in Settings → ACP Clients.",
                        isError: true
                    )))
                    c.yield(.result(ResultEvent(
                        durationMs: nil, totalCostUsd: nil,
                        sessionId: cliSessionId ?? sessionKey,
                        isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                    )))
                    c.finish()
                }
            }
        }

        let stream: AsyncStream<StreamEvent>
        if let earlyStream {
            stream = earlyStream
        } else {
            let request = BackendSendRequest(
                streamId: streamId,
                prompt: resolvedPrompt,
                cwd: cwd,
                sessionId: cliSessionId,
                model: resolvedModel,
                effort: effort,
                permissionMode: resolvedSendMode,
                planMode: permissionMode == .plan,
                hookSettingsPath: hookSettingsPath,
                mcpClaudeConfigPath: mcpClaudeConfigPath,
                extraSystemPrompt: extraSystemPrompt,
                mcpCodexOverrides: mcpCodexOverrides,
                acpMCPServers: acpMCPServers,
                acpSpec: acpSpec,
                clientSessionKey: sessionKey
            )
            stream = await backend(for: agentProvider).send(request)
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

        do {
            for await event in stream {
                eventCount += 1
                let gap = Date().timeIntervalSince(lastEventTime)
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
                        if sessionKey != resultEvent.sessionId {
                            if let state = sessionStates.removeValue(forKey: sessionKey) {
                                sessionStates[resultEvent.sessionId] = state
                            }
                            sessionIdRedirect[sessionKey] = resultEvent.sessionId
                            sessionKey = resultEvent.sessionId
                        }
                        let msgs = stateForSession(sessionKey).messages
                        if !msgs.isEmpty {
                            await saveSession(sessionId: resultEvent.sessionId, projectId: projectId, messages: msgs)
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
                    // Hook events (SessionStart, PreToolUse, etc.) carry the parent's session_id,
                    // not this subprocess's. Acting on them flips currentSessionId mid-stream and
                    // triggers MessageListView's fade-out/in — visible as a blink.
                    let isHookEvent = systemEvent.subtype.hasPrefix("hook_")
                    if let sid = systemEvent.sessionId, !isHookEvent {
                        await permission.registerSession(sid: sid, projectKey: cwd, mode: registerMode)
                        // Capture the sessionKey BEFORE the reassignment so the
                        // reconciler can rename the previous row in place when
                        // the CLI advances `session_id` mid-stream.
                        let previousSessionKey = sessionKey
                        if sessionKey != sid {
                            if let state = sessionStates.removeValue(forKey: previousSessionKey) {
                                sessionStates[sid] = state
                            }
                            renameDraftState(from: previousSessionKey, to: sid, in: window)
                            sessionIdRedirect[previousSessionKey] = sid
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

                case .user(let userMessage):
                    logger.debug("[Stream:UI] event #\(eventCount) .user (gap=\(String(format: "%.1f", gap))s, toolUseId=\(userMessage.toolUseId ?? "none"))")
                    updateState(sessionKey) { state in
                        guard let toolUseId = userMessage.toolUseId else { return }
                        state.pendingToolResults.append((toolUseId, userMessage.content, userMessage.isError))
                        state.needsNewMessage = true
                    }

                case .result(let resultEvent):
                    logger.info("[Stream:UI] event #\(eventCount) .result (gap=\(String(format: "%.1f", gap))s, isError=\(resultEvent.isError), session=\(resultEvent.sessionId))")

                    // With `--input-format stream-json` the CLI stays alive waiting for more
                    // input. Close stdin on `result` so it exits cleanly, then finalize so
                    // any subagent children that survived the parent CLI get reaped.
                    await finalizeAgentStream(agentProvider: agentProvider, streamId: streamId)

                    if sessionKey != resultEvent.sessionId {
                        let previousSessionKey = sessionKey
                        let wasForeground = (window.currentSessionId ?? window.newSessionKey) == previousSessionKey
                        if let state = sessionStates.removeValue(forKey: previousSessionKey) {
                            sessionStates[resultEvent.sessionId] = state
                        }
                        renameDraftState(from: previousSessionKey, to: resultEvent.sessionId, in: window)
                        sessionIdRedirect[previousSessionKey] = resultEvent.sessionId
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

                    // A background completion is "finished, unread". Setting the
                    // flag inside finalizeStreamSession means the trailing
                    // `.streamingFinished` broadcast already carries it to mobile.
                    let isFg = (window.currentSessionId ?? window.newSessionKey) == sessionKey
                    let markUnread = !isFg && !resultEvent.isError

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

                    recordStreamCompletion(
                        streamId: streamId,
                        sessionId: resultEvent.sessionId,
                        assistantText: lastAssistantResponseText(in: stateForSession(sessionKey).messages),
                        error: resultEvent.isError ? "Agent reported an error result." : nil
                    )

                    if isFg {
                        window.currentSessionId = resultEvent.sessionId
                        if resultEvent.isError {
                            let errText = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)
                                ?? "\(agentProvider.displayNameText) returned an error."
                            addErrorMessage(errText, in: window)
                        }
                    }

                    await saveSession(
                        sessionId: resultEvent.sessionId,
                        projectId: projectId,
                        messages: stateForSession(sessionKey).messages
                    )

                    if agentProvider == .claudeCode {
                        reconcileFromDisk(sessionId: resultEvent.sessionId, projectId: projectId, cwd: cwd)
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

                        if notificationsEnabled {
                            let summary = allSessionSummaries.first(where: { $0.id == resultEvent.sessionId })
                            let title = summary?.title ?? "New Session"
                            let responseText = lastAssistantResponseText(in: stateForSession(sessionKey).messages)
                            let fallbackBody = responseNotificationFallback(from: responseText)
                            let pid = projectId
                            let sid = resultEvent.sessionId
                            let postLocalBanner = !NSApp.isActive
                            Task { [weak self] in
                                var body = fallbackBody
                                if let self, let summary {
                                    body = await self.generateResponseNotificationSummary(responseText: responseText, summary: summary) ?? fallbackBody
                                }
                                await NotificationService.shared.postResponseComplete(title: title, body: body, projectId: pid, sessionId: sid, postLocalBanner: postLocalBanner)
                            }
                        }

                        scheduleThreadSummaryUpdate(
                            sessionId: resultEvent.sessionId,
                            projectId: projectId,
                            cwd: cwd,
                            messages: stateForSession(sessionKey).messages
                        )
                        scheduleMemoryExtraction(
                            sessionId: resultEvent.sessionId,
                            projectId: projectId,
                            messages: stateForSession(sessionKey).messages
                        )

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
                    broadcastMobileSessionStatus(sessionID: targetSession)

                case .acpModelsDiscovered(let event):
                    logger.info("[Stream:UI] event #\(eventCount) .acpModelsDiscovered clientId=\(event.clientId, privacy: .public) configId=\(event.config.configId, privacy: .public) models=\(event.config.options.count) [\(Self.acpModelListDescription(event.config.options), privacy: .public)]")
                    applyDiscoveredACPModels(clientId: event.clientId, config: event.config)

                case .unknown(let raw):
                    if eventCount <= 5 || eventCount % 100 == 0 {
                        logger.debug("[Stream:UI] event #\(eventCount) .unknown (gap=\(String(format: "%.1f", gap))s, len=\(raw.count))")
                    }
                    handlePartialEvent(raw, for: sessionKey)
                }
            }

            let elapsed = Date().timeIntervalSince(streamStart)
            logger.info("[Stream:UI] stream ended after \(eventCount) events, \(String(format: "%.1f", elapsed))s total")

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
            if pendingStreamCompletions[streamId] == nil {
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
        }
    }

}
