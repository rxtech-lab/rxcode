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
            await cancelStreaming(in: window)
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
        // Right sidebar visibility lives in UserDefaults (read via @AppStorage
        // in views). Writing here triggers those views to update.
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.showRightSidebar
        if defaults.bool(forKey: key), window.inspectorTab == .terminal {
            defaults.set(false, forKey: key)
        } else {
            window.inspectorTab = .terminal
            defaults.set(true, forKey: key)
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
        in window: WindowState
    ) async -> UUID? {
        guard let project = window.selectedProject else {
            handleError(AppError.noProjectSelected, in: window)
            return nil
        }

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        let streamId = UUID()
        let isNewSession = window.currentSessionId == nil
        let isPending = window.currentSessionId.map { window.pendingPlaceholderIds.contains($0) } ?? false
        let cliSessionId: String? = (isNewSession || isPending) ? nil : window.currentSessionId

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

    /// Record that the stream `streamId` finished. Stored in
    /// `pendingStreamCompletions` for any `awaitStreamCompletion(...)` caller
    /// (currently `ide__send_to_thread`) to pick up. Latest call wins, except
    /// we don't overwrite a success with an error from the fallback path.
    func recordStreamCompletion(
        streamId: UUID,
        sessionId: String,
        assistantText: String,
        error: String?
    ) {
        pendingStreamCompletions[streamId] = StreamCompletion(
            sessionId: sessionId,
            assistantText: assistantText,
            error: error
        )
    }

    /// Wait up to `timeout` seconds for the stream identified by `streamId`
    /// to record a completion. Polls every 100ms — MainActor serialization
    /// means the recorder fires between sleeps. Returns the completion if
    /// one arrived in time, otherwise `nil`.
    func awaitStreamCompletion(streamId: UUID, timeout: TimeInterval) async -> StreamCompletion? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let completion = pendingStreamCompletions.removeValue(forKey: streamId) {
                return completion
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return pendingStreamCompletions.removeValue(forKey: streamId)
    }

    /// Discard a recorded completion. Called by long-running `wait_for_response=false`
    /// MCP sends so the dictionary doesn't grow unbounded with abandoned results.
    func discardStreamCompletion(streamId: UUID) {
        pendingStreamCompletions.removeValue(forKey: streamId)
    }

}
