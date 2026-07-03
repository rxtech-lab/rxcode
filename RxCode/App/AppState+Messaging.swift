import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Edit & Resend

    func editAndResend(messageId: UUID, newContent: String, in window: WindowState) async {
        let key = window.currentSessionId ?? window.newSessionKey
        var snapshot = sessionStates[key]?.messages ?? []
        guard let index = snapshot.firstIndex(where: { $0.id == messageId }),
              snapshot[index].role == .user else { return }

        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isStreaming(in: window) {
            // Interrupting to resend an edited message — a new turn starts
            // immediately, so don't fire the session-stop hooks.
            await cancelStreaming(in: window, fireStopHooks: false)
        }

        snapshot.removeSubrange((index + 1)...)
        snapshot[index].content = trimmed

        window.currentSessionId = nil
        sessionStates.removeValue(forKey: window.newSessionKey)
        await sendPrompt(trimmed, skipAppendingUserMessage: true, initialMessages: snapshot, in: window)
    }

    // MARK: - Send Message

    func send(in window: WindowState) async {
        let prompt = window.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAttachments = window.attachments
        guard !prompt.isEmpty || !currentAttachments.isEmpty else { return }

        // S2: warn (in logs) if another process touched the same jsonl very
        // recently — likely a `claude` running in the terminal on the same
        // session. We don't block, but the operator can spot it after the fact.
        if effectiveModelSelection(in: window).provider == .claudeCode,
           let sid = window.currentSessionId,
           let cwd = window.selectedProject?.path,
           cliStore.detectExternalActivity(sid: sid, cwd: cwd, withinSeconds: 5)
        {
            logger.warning("Session \(sid, privacy: .public) jsonl was modified within 5s — another claude process may be active")
        }

        if currentAttachments.isEmpty, await handleNativeSlashCommand(prompt, in: window) {
            window.inputText = ""
            return
        }

        window.inputText = ""
        window.draftTexts.removeValue(forKey: draftKey(for: window))
        window.attachments = []

        let (resolvedAttachments, tempFilePaths) = AttachmentFactory.resolvingClipboardImages(currentAttachments)
        let fullPrompt = buildPromptWithAttachments(prompt, attachments: resolvedAttachments)

        await sendPrompt(fullPrompt, displayText: prompt, attachments: resolvedAttachments,
                         tempFilePaths: tempFilePaths, in: window)
    }

    /// Slash commands handled natively. Returns true if handled.
    func handleNativeSlashCommand(_ text: String, in window: WindowState) async -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.split(separator: " ", maxSplits: 1)
        let command = parts.first.map { String($0.dropFirst()) } ?? ""

        switch command {
        case "clear":
            startNewChat(in: window)
            return true
        case "model":
            if parts.count > 1 {
                let arg = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                let flattened = availableAgentModelSections().flatMap(\.models)
                let matched = flattened.first { $0.id.lowercased() == arg }
                    ?? flattened.first { arg.contains($0.id.lowercased()) }
                setSessionModel(matched?.id ?? arg, provider: matched?.provider, in: window)
            } else {
                window.showModelPicker = true
            }
            return true
        case "effort":
            if parts.count > 1 {
                let arg = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                setSessionEffort(Self.availableEfforts.contains(arg) ? arg : nil, in: window)
            } else {
                window.showEffortPicker = true
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Send Slash Command

    func sendSlashCommand(_ command: String, in window: WindowState) async {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if await handleNativeSlashCommand(trimmed, in: window) { return }

        let baseName = trimmed.split(separator: " ", maxSplits: 1)
            .first.map { String($0.dropFirst()) } ?? ""

        let isInteractive = SlashCommandRegistry.commands
            .first { $0.name == baseName }?.isInteractive ?? false

        if isInteractive {
            await sendInteractiveCommand(trimmed, in: window)
        } else {
            await sendPrompt(trimmed, in: window)
        }
    }

    func sendInteractiveCommand(_ command: String, in window: WindowState) async {
        let title = command.trimmingCharacters(in: .whitespaces)
        await launchTerminal(title: title, initialCommand: command, in: window)
    }

    func runTerminalCommand(_ command: String, in window: WindowState) async {
        let title = command.trimmingCharacters(in: .whitespaces)
        await launchTerminal(title: title, initialCommand: command, rawShell: true, in: window)
    }

    func openTerminal(in window: WindowState) async {
        if showRightSidebar, window.inspectorTab == .terminal {
            showRightSidebar = false
        } else {
            window.inspectorTab = .terminal
            showRightSidebar = true
        }
    }

    func launchTerminal(
        title: String,
        initialCommand: String? = nil,
        reportToChat: Bool = true,
        rawShell: Bool = false,
        in window: WindowState
    ) async {
        guard let project = window.selectedProject else {
            handleError(AppError.noProjectSelected, in: window)
            return
        }

        let arguments: [String]
        if rawShell {
            arguments = ["-il"]
        } else {
            guard let binary = await claude.findClaudeBinary() else {
                handleError(AppError.claudeNotInstalled, in: window)
                return
            }
            arguments = ["-ilc", binary]
        }

        window.interactiveTerminal = InteractiveTerminalState(
            title: title,
            executable: "/bin/zsh",
            arguments: arguments,
            currentDirectory: project.path,
            initialCommand: initialCommand,
            reportToChat: reportToChat
        )
    }

    func dismissInteractiveTerminal(exitCode: Int32, in window: WindowState) {
        guard let terminal = window.interactiveTerminal else { return }
        window.interactiveTerminal = nil

        guard terminal.reportToChat else { return }

        let key = window.currentSessionId ?? window.newSessionKey
        let wasFirstUserMessage = (sessionStates[key]?.messages.filter { $0.role == .user }.count ?? 0) == 0
        updateState(key) { state in
            state.messages.append(ChatMessage(role: .user, content: terminal.title))
            let result = exitCode == 0 ? "Done" : "exit code: \(exitCode)"
            let toolCall = ToolCall(
                id: UUID().uuidString,
                name: InteractiveTerminalState.toolName,
                input: ["command": .string(terminal.title)],
                result: result,
                isError: exitCode != 0
            )
            state.messages.append(ChatMessage(role: .assistant, blocks: [.toolCall(toolCall)]))
        }
        if wasFirstUserMessage, !(sessionStates[key]?.titleGenerationTriggered ?? false) {
            updateState(key) { $0.titleGenerationTriggered = true }
            Task { [weak self] in
                guard let self else { return }
                await self.maybeGenerateLLMTitle(for: key)
            }
        }
        Task { await saveCurrentSession(in: window) }
    }

    // MARK: - Shared Send Logic

    @discardableResult
    func sendPrompt(
        _ prompt: String,
        displayText: String? = nil,
        attachments: [Attachment] = [],
        skipAppendingUserMessage: Bool = false,
        initialMessages: [ChatMessage]? = nil,
        tempFilePaths: [String] = [],
        isStopHookReprompt: Bool = false,
        debugLogPrefix: String? = nil,
        includeIDEMCP: Bool = true,
        in window: WindowState
    ) async -> UUID? {
        guard let project = window.selectedProject else {
            handleError(AppError.noProjectSelected, in: window)
            return nil
        }

        if isStreaming(in: window) {
            // A new prompt interrupts the in-flight stream; the session isn't
            // stopping (a new turn begins now), so skip the session-stop hooks.
            await cancelStreaming(in: window, fireStopHooks: false)
        }

        let streamId = UUID()
        if let debugLogPrefix {
            streamDebugLogPrefixes[streamId] = debugLogPrefix
        }
        let isNewSession = window.currentSessionId == nil
        let isPending = window.currentSessionId.map { window.pendingPlaceholderIds.contains($0) } ?? false
        // Resolve the resume id per provider: a thread that ran under Claude and
        // is now switched to Codex must NOT hand Codex the Claude session id.
        // The switched provider resumes its own recorded native id, or starts a
        // fresh native session when it has never run on this thread.
        let cliSessionId: String?
        if isNewSession || isPending {
            cliSessionId = nil
        } else {
            let resumeProvider = effectiveModelSelection(in: window).provider
            cliSessionId = resumeSessionId(for: resumeProvider, threadId: window.currentSessionId!)
        }
        if let debugLogPrefix {
            logger.info("\(debugLogPrefix, privacy: .public) phase=sendPrompt stream=\(streamId) isNewSession=\(isNewSession, privacy: .public) isPending=\(isPending, privacy: .public) cliSession=\(cliSessionId ?? "<new>", privacy: .public)")
        }

        if isNewSession {
            let tempId = "pending-\(streamId.uuidString)"
            window.currentSessionId = tempId
            window.insertPendingPlaceholder(tempId)
            let snapSelection = effectiveModelSelection(in: window)
            let snapProvider = snapSelection.provider
            let snapModel = snapSelection.model
            window.sessionAgentProvider = snapProvider
            window.sessionModel = snapModel
            let snapEffort = window.sessionEffort
            let snapPermission = window.sessionPermissionMode
            let pendingWorktreePath = window.pendingWorktreePath
            let pendingWorktreeBranch = window.pendingWorktreeBranch
            updateState(tempId) { state in
                state.agentProvider = snapProvider
                state.model = snapModel
                state.effort = snapEffort
                state.permissionMode = snapPermission
                state.worktreePath = pendingWorktreePath
                state.worktreeBranch = pendingWorktreeBranch
            }
            window.pendingWorktreePath = nil
            window.pendingWorktreeBranch = nil
        }

        let sessionKey = window.currentSessionId!

        // A real user turn clears the stop-hook auto-continue tally so a fresh
        // round of fix→fail→fix gets the full retry budget again. A reprompt
        // turn (this method calling itself) must not reset it. The code-review
        // fix-round counter resets on the same terms (and the review fix turn is
        // also sent with `isStopHookReprompt`, so it won't reset its own bound).
        if !isStopHookReprompt {
            stopHookRepromptCounts[sessionKey] = nil
            reviewRoundBySession[sessionKey] = nil
            // Drop the carried-over review feedback too: a fresh user turn is a
            // new change, so the next review should start from scratch rather
            // than chasing the last turn's findings.
            lastReviewFeedbackBySession[sessionKey] = nil
            // A new follow-up message supersedes any pending/in-flight automatic
            // code review for this thread: cancel the countdown and stop the
            // review thread if it's already running. Auto-fix reprompts (sent
            // with `isStopHookReprompt`) deliberately don't cancel — they want
            // the re-review to run.
            reviewScheduler?.cancel(parentSessionKey: sessionKey, reason: .newMessage)
        }

        // Apply initialMessages if provided. Refuse to clobber an already-
        // populated in-memory list with an empty array — `editAndResend` is
        // the only documented caller and always supplies a non-empty truncated
        // history, so an empty `initial` would be a regression that erases
        // the user's chat.
        if let initial = initialMessages, !initial.isEmpty {
            updateState(sessionKey) { $0.messages = initial }
        } else if let initial = initialMessages, initial.isEmpty {
            let existing = sessionStates[sessionKey]?.messages.count ?? 0
            logger.error("[sendPrompt] refusing to overwrite \(existing) messages with empty initialMessages for session=\(sessionKey, privacy: .public)")
        }

        let wasFirstUserMessage = (sessionStates[sessionKey]?.messages.filter { $0.role == .user }.count ?? 0) == 0
        if !skipAppendingUserMessage {
            updateState(sessionKey) { state in
                state.messages.append(ChatMessage(
                    role: .user,
                    content: displayText ?? prompt,
                    attachments: attachments
                ))
                state.inFlightUserAttachments = attachments
            }
            // A genuine user message resets the Send Message hook's once-per-session
            // guard so it can fire again. The hook's own injected message marks the
            // session *after* this point (in `sendCrossProject`), so it isn't cleared
            // here. Stop-hook reprompts aren't user turns and must not reset it.
            if !isStopHookReprompt {
                clearSetupSession(kind: HookSetupKind.sendMessage, sessionKey: sessionKey)
            }
        }

        // Insert the placeholder summary before kicking off title generation —
        // the Task below awaits and the lookup in maybeGenerateLLMTitle would
        // otherwise race the insertion at line ~1168 and bail with "no summary".
        if isNewSession {
            let initialTitle = ChatSession.placeholderTitle(from: displayText ?? prompt)
            let selection = effectiveModelSelection(in: window)
            let provider = selection.provider
            let placeholder = ChatSession(
                id: sessionKey,
                projectId: project.id,
                title: initialTitle,
                messages: [],
                agentProvider: provider,
                model: selection.model,
                origin: provider.defaultSessionOrigin,
                worktreePath: sessionStates[sessionKey]?.worktreePath,
                worktreeBranch: sessionStates[sessionKey]?.worktreeBranch
            )
            allSessionSummaries.insert(placeholder.summary, at: 0)
            threadStore.upsert(placeholder.summary)
        }

        // Kick off LLM title generation as soon as the first user message lands —
        // the rename runs concurrently with the stream so the sidebar title updates
        // without waiting for the assistant to reply.
        if wasFirstUserMessage,
           !skipAppendingUserMessage,
           !(sessionStates[sessionKey]?.titleGenerationTriggered ?? false)
        {
            updateState(sessionKey) { $0.titleGenerationTriggered = true }
            let titleKey = sessionKey
            Task { [weak self] in
                guard let self else { return }
                await self.maybeGenerateLLMTitle(for: titleKey)
            }
        }

        updateState(sessionKey) { state in
            state.isStreaming = true
            state.hasUncheckedCompletion = false
            state.activeStreamId = streamId
            state.streamingStartDate = Date()
            state.currentTurnOutputTokensByMessage.removeAll(keepingCapacity: true)
            state.currentTurnOutputTokensUnkeyed = 0
        }
        broadcastMobileSessionStatus(sessionID: sessionKey, kind: .streamingStarted)

        let basePermissionMode = window.sessionPermissionMode ?? permissionMode
        // Plan-mode boolean overrides the dropdown for the CLI `--permission-mode` flag only.
        // The dropdown choice is preserved and re-applied automatically once plan-mode is toggled back off.
        let cliPermissionMode: PermissionMode = window.sessionPlanMode ? .plan : basePermissionMode
        // PermissionServer registration uses the dropdown value directly so an explicit Auto
        // choice continues to auto-approve hook-matched tools while plan mode is on.
        // ExitPlanMode is always exempt from auto-approve (see PermissionServer.autoApproveReason),
        // so the plan card still surfaces.
        let hookSessionMode = basePermissionMode
        let launchAgentProvider = sessionStates[sessionKey]?.agentProvider
            ?? window.sessionAgentProvider
            ?? selectedAgentProvider
        var hookSettingsPath: String?
        if launchAgentProvider == .claudeCode, !cliPermissionMode.skipsHookPipeline {
            do {
                hookSettingsPath = try await permission.writeHookSettingsFile()
            } catch {
                logger.error("Failed to write hook settings: \(error.localizedDescription)")
            }
        }

        // Resume already has the sid; new sessions register on first system event.
        if let sid = cliSessionId {
            await permission.registerSession(sid: sid, projectKey: project.path, mode: hookSessionMode)
        }

        if !isNewSession {
            await saveCurrentSession(in: window)
        }

        let effectiveCwd = sessionStates[sessionKey]?.worktreePath
            ?? allSessionSummaries.first(where: { $0.id == sessionKey })?.worktreePath
            ?? project.path
        let selection = effectiveModelSelection(in: window)
        let effectiveProvider = sessionStates[sessionKey]?.agentProvider ?? selection.provider
        let effectiveModel = sessionStates[sessionKey]?.model ?? selection.model
        if let debugLogPrefix {
            logger.info("\(debugLogPrefix, privacy: .public) phase=sendPromptReady stream=\(streamId) sessionKey=\(sessionKey, privacy: .public) provider=\(effectiveProvider.rawValue, privacy: .public) model=\(effectiveModel ?? "<default>", privacy: .public) cwd=\(effectiveCwd, privacy: .public)")
        }

        let task = Task { [weak self, window] in
            guard let self else { return }
            await self.processStream(
                streamId: streamId,
                prompt: prompt,
                cwd: effectiveCwd,
                cliSessionId: cliSessionId,
                internalSessionKey: sessionKey,
                agentProvider: effectiveProvider,
                model: effectiveModel,
                effort: window.sessionEffort ?? (self.selectedEffort == "auto" ? nil : self.selectedEffort),
                hookSettingsPath: hookSettingsPath,
                permissionMode: cliPermissionMode,
                hookSessionMode: hookSessionMode,
                projectId: project.id,
                includeIDEMCP: includeIDEMCP,
                window: window
            )
            for path in tempFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        sessionStates[sessionKey, default: SessionStreamState()].streamTask = task
        return streamId
    }

    // MARK: - Stream Processing

    func stateForSession(_ key: String) -> SessionStreamState {
        sessionStates[key] ?? SessionStreamState()
    }

    func updateState(_ key: String, _ mutate: (inout SessionStreamState) -> Void) {
        let prevMessages = sessionStates[key]?.messages ?? []
        let prevThinking = sessionStates[key]?.isThinking ?? false
        guard var state = sessionStates[key] else {
            var fresh = SessionStreamState()
            mutate(&fresh)
            sessionStates[key] = fresh
            broadcastMobileMessageDiff(sessionKey: key, prev: prevMessages, next: fresh.messages, isStreaming: fresh.isStreaming)
            broadcastMobileThinkingChange(sessionKey: key, prev: prevThinking, next: fresh.isThinking, isStreaming: fresh.isStreaming)
            return
        }
        mutate(&state)
        sessionStates[key] = state
        broadcastMobileMessageDiff(sessionKey: key, prev: prevMessages, next: state.messages, isStreaming: state.isStreaming)
        broadcastMobileThinkingChange(sessionKey: key, prev: prevThinking, next: state.isThinking, isStreaming: state.isStreaming)
    }

    /// Mirror `isThinking` transitions to paired mobile devices so the remote
    /// streaming indicator can show a "Thinking…" label. Only fires on an
    /// actual change — the flag flips repeatedly within a turn and we don't
    /// want to flood the relay with redundant updates.
    func broadcastMobileThinkingChange(sessionKey: String, prev: Bool, next: Bool, isStreaming: Bool) {
        guard prev != next, !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionKey,
            kind: .statusChanged,
            message: nil,
            isStreaming: isStreaming,
            isThinking: next
        )
    }

    func finalizeStreamSession(
        for sessionKey: String,
        extraMutations: ((inout SessionStreamState) -> Void)? = nil
    ) {
        flushPendingUpdates(for: sessionKey, forceText: true)
        updateState(sessionKey) { state in
            state.flushTask?.cancel()
            state.flushTask = nil
            state.isStreaming = false
            state.isThinking = false
            state.needsNewMessage = false
            state.activeStreamId = nil
            state.streamTask = nil
            state.activeToolId = nil
            state.activeToolInputBuffer = ""
            state.textDeltaBuffer = ""
            state.pendingToolResults.removeAll()
            state.lastStreamEventDate = nil

            extraMutations?(&state)

            if let idx = state.messages.indices.reversed().first(where: {
                state.messages[$0].role == .assistant && state.messages[$0].isStreaming
            }) {
                state.messages[idx].isStreaming = false
                state.messages[idx].isResponseComplete = true
                state.messages[idx].finalizeToolCalls()
                if let start = state.streamingStartDate {
                    state.messages[idx].duration = Date().timeIntervalSince(start)
                }
                Self.stripNoOpText(at: idx, in: &state.messages)
            }
            state.streamingStartDate = nil
        }
        broadcastMobileSessionStatus(sessionID: sessionKey, kind: .streamingFinished)
        Task { @MainActor [weak self] in
            await self?.flushNextQueuedMessageIfNeeded(sessionID: sessionKey)
        }
    }

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

/// Resumes a single waiting `awaitSessionRename` caller. Same single-shot
/// pattern as `StreamCompletionWaiter` — guards against double-resume in the
/// race between the rename notification and the timeout task.
@MainActor
final class SessionRenameWaiter {
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: String?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: value)
    }
}

/// Resumes a single waiting `awaitStreamCompletion` caller. The class wrapper
/// guards against double-resume in the race between `recordStreamCompletion`
/// and the timeout task: whichever fires first wins, and the other becomes a
/// no-op when it finds the continuation already consumed.
@MainActor
final class StreamCompletionWaiter {
    private var continuation: CheckedContinuation<AppState.StreamCompletion?, Never>?
    let acceptsPartial: Bool

    init(
        continuation: CheckedContinuation<AppState.StreamCompletion?, Never>,
        acceptsPartial: Bool
    ) {
        self.continuation = continuation
        self.acceptsPartial = acceptsPartial
    }

    func resume(with value: AppState.StreamCompletion?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: value)
    }
}
