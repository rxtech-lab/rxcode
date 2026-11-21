import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {

    // MARK: - Text Delta Grouping

    func startFlushTimer(for sessionKey: String) {
        stopFlushTimer(for: sessionKey)
        let capturedKey = sessionKey
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { break }
                self?.flushPendingUpdates(for: capturedKey)
            }
        }
        sessionStates[sessionKey, default: SessionStreamState()].flushTask = task
    }

    func stopFlushTimer(for sessionKey: String) {
        sessionStates[sessionKey]?.flushTask?.cancel()
        sessionStates[sessionKey]?.flushTask = nil
    }

    func flushPendingUpdates(for key: String, forceText: Bool = false) {
        guard var state = sessionStates[key] else { return }

        let hasText = !state.textDeltaBuffer.isEmpty
        let hasToolResults = !state.pendingToolResults.isEmpty
        let textGroup: String?
        if hasText {
            if forceText || hasToolResults {
                textGroup = state.textDeltaBuffer
                state.textDeltaBuffer = ""
            } else if let group = Self.nextStreamingTextGroup(from: state.textDeltaBuffer) {
                textGroup = group.text
                state.textDeltaBuffer = group.remainder
            } else {
                textGroup = nil
            }
        } else {
            textGroup = nil
        }

        guard textGroup != nil || hasToolResults else { return }

        let prevMessages = state.messages

        func lastAssistantIdx() -> Int? {
            state.messages.indices.reversed().first { state.messages[$0].role == .assistant }
        }
        func lastStreamingAssistantIdx() -> Int? {
            state.messages.indices.reversed().first { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }
        }

        // 1. Tool results — match each `toolUseId` against its owning assistant message
        //    (not just `lastAssistantIdx()`, since parallel/interleaved tool calls in
        //    Codex/ACP can span earlier assistant bubbles).
        if hasToolResults {
            let results = state.pendingToolResults
            state.pendingToolResults.removeAll(keepingCapacity: true)
            for (toolUseId, content, isError) in results {
                let matchedIdx = state.messages.indices.reversed().first(where: {
                    state.messages[$0].role == .assistant && state.messages[$0].toolCallIndex(id: toolUseId) != nil
                }) ?? lastAssistantIdx()
                guard let idx = matchedIdx else { continue }

                let completedCall = state.messages[idx].toolCallIndex(id: toolUseId)
                    .flatMap { state.messages[idx].blocks[$0].toolCall }
                let editPersistInfos: [(path: String, hunks: [PreviewFile.EditHunk], isWrite: Bool)] = {
                    guard !isError,
                          let call = completedCall,
                          ["edit", "multiedit", "multi_edit", "write"].contains(call.name.lowercased())
                    else { return [] }
                    let claudeHunks = call.fileEditHunks
                    if !claudeHunks.isEmpty, let path = call.editedFilePath {
                        return [(path, claudeHunks, call.name.lowercased() == "write")]
                    }
                    // Codex `fileChange` shape: one tool call may touch multiple files.
                    let codexDiffs = call.fileChangeDiffs
                    guard !codexDiffs.isEmpty else { return [] }
                    return codexDiffs.map { ($0.path, [$0.hunk], false) }
                }()
                // Preserve the user-decision summary on ExitPlanMode. After the user
                // accepts/rejects the plan, the CLI emits its own follow-up tool_result
                // ("User has approved your plan…") which would overwrite "Accepted with …"
                // and flip the plan card back to "pending" — re-showing the accept buttons
                // on a card that was just decided.
                let skipResultOverwrite: Bool = {
                    guard let call = completedCall,
                          Self.isExitPlanModeCall(call),
                          let existing = call.result else { return false }
                    return Self.planDecisionResultPrefixes.contains { existing.hasPrefix($0) }
                }()
                if !skipResultOverwrite {
                    state.messages[idx].setToolResult(id: toolUseId, result: content, isError: isError)
                }
                persistStructuredFileEdits(editPersistInfos, state: state, sessionKey: key)
                handleCompletedShellToolCallIfNeeded(call: completedCall, sessionKey: key, state: state)
            }
        }

        // 2. Text delta flush
        if let buffered = textGroup, !buffered.isEmpty {
            if let idx = lastStreamingAssistantIdx() {
                if state.needsNewMessage {
                    // New turn segment after receiving tool result — start a new ChatMessage
                    // without dropping sibling parallel tool calls still awaiting results.
                    state.messages[idx].isStreaming = false
                    state.messages[idx].finalizeToolCalls(dropIncomplete: false)
                    Self.stripNoOpText(at: idx, in: &state.messages)
                    state.needsNewMessage = false
                    state.messages.append(ChatMessage(role: .assistant, content: buffered, isStreaming: true))
                } else {
                    state.messages[idx].appendText(buffered)
                }
            } else {
                state.messages.append(ChatMessage(role: .assistant, content: buffered, isStreaming: true))
            }
        }

        sessionStates[key] = state
        broadcastMobileMessageDiff(sessionKey: key, prev: prevMessages, next: state.messages, isStreaming: state.isStreaming)
    }

    private static let streamingTextGroupTokenCount = 10

    private static func nextStreamingTextGroup(from text: String) -> (text: String, remainder: String)? {
        var tokenCount = 0
        var isInsideToken = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if isInsideToken {
                    isInsideToken = false
                    if tokenCount >= streamingTextGroupTokenCount {
                        var splitIndex = text.index(after: index)
                        while splitIndex < text.endIndex, text[splitIndex].isWhitespace {
                            splitIndex = text.index(after: splitIndex)
                        }
                        return (String(text[..<splitIndex]), String(text[splitIndex...]))
                    }
                }
            } else if !isInsideToken {
                tokenCount += 1
                isInsideToken = true
                if tokenCount > streamingTextGroupTokenCount {
                    return (String(text[..<index]), String(text[index...]))
                }
            }

            index = text.index(after: index)
        }

        guard tokenCount >= streamingTextGroupTokenCount else { return nil }
        return (text, "")
    }

    // MARK: - Stream Event Handler

    func handlePartialEvent(_ raw: String, for sessionKey: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let event: [String: Any]
        if let type = json["type"] as? String, type == "stream_event",
           let nested = json["event"] as? [String: Any]
        {
            event = nested
        } else {
            event = json
        }

        guard let eventType = event["type"] as? String else { return }

        switch eventType {
        case "content_block_start":
            guard let contentBlock = event["content_block"] as? [String: Any],
                  let blockType = contentBlock["type"] as? String else { return }

            if blockType == "tool_use" {
                guard let id = contentBlock["id"] as? String,
                      let name = contentBlock["name"] as? String else { return }
                beginToolCall(id: id, name: name, for: sessionKey)
            } else if blockType == "text" {
                // New text block started — if needsNewMessage, prepare a new ChatMessage
                updateState(sessionKey) { state in
                    if state.needsNewMessage {
                        // Keep the flag so a new message is created on the next text_delta flush
                        // (needsNewMessage is handled inside flush)
                    }
                    state.isThinking = false
                    state.activeToolId = nil
                    state.activeToolInputBuffer = ""
                }
            } else if blockType == "thinking" {
                updateState(sessionKey) { $0.isThinking = true }
            }

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return }

            if deltaType == "text_delta", let text = delta["text"] as? String {
                applyTextDelta(text, for: sessionKey)
            } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                updateState(sessionKey) { state in
                    state.activeToolInputBuffer += partial
                }
            } else if deltaType == "thinking_delta" {
                applyThinkingDelta(for: sessionKey)
            }

        case "content_block_stop":
            // Finalize tool_use input — parse the accumulated JSON and apply to the tool call.
            // Only Claude's wire format streams arguments in fragments, so this
            // is the one place that has to reassemble them; backends built on
            // RxAgentSDK deliver the parsed input as `.toolCallInput`.
            let pending: (id: String, input: [String: JSONValue])? = {
                var result: (String, [String: JSONValue])?
                updateState(sessionKey) { state in
                    guard let toolId = state.activeToolId, !state.activeToolInputBuffer.isEmpty else {
                        state.activeToolId = nil
                        return
                    }
                    let buffer = state.activeToolInputBuffer
                    state.activeToolId = nil
                    state.activeToolInputBuffer = ""

                    guard let inputData = buffer.data(using: .utf8),
                          let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: inputData)
                    else { return }
                    result = (toolId, parsed)
                }
                return result
            }()
            if let pending {
                applyToolCallInput(id: pending.id, input: pending.input, for: sessionKey)
            }

        default:
            break
        }
    }

    // MARK: - Block Application
    //
    // The bodies below are shared by two producers: `handlePartialEvent(_:for:)`
    // above, which decodes Claude's raw wire frames, and the RxAgentSDK-backed
    // backends, which emit `StreamEvent.textDelta` / `.toolCallStarted` /
    // `.toolCallInput` already decoded. Keeping one implementation means the
    // two paths cannot drift.

    /// Append a chunk of assistant text to the session's delta buffer.
    func applyTextDelta(_ text: String, for sessionKey: String) {
        guard !text.isEmpty else { return }
        updateState(sessionKey) { state in
            state.isThinking = false
            state.textDeltaBuffer += text
        }
    }

    /// Note that the model is reasoning. The text itself is not rendered yet.
    func applyThinkingDelta(for sessionKey: String) {
        updateState(sessionKey) { $0.isThinking = true }
    }

    /// Open a tool call whose arguments have not arrived yet.
    func beginToolCall(id: String, name: String, for sessionKey: String) {
        // Flush the text buffer first so text blocks are committed before tools
        flushPendingUpdates(for: sessionKey, forceText: true)
        updateState(sessionKey) { state in
            state.isThinking = false
            // needsNewMessage: new turn segment after tool result — create a new ChatMessage
            // without discarding any sibling parallel tool calls still awaiting results.
            if state.needsNewMessage {
                if let idx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }) {
                    state.messages[idx].isStreaming = false
                    state.messages[idx].finalizeToolCalls(dropIncomplete: false)
                    Self.stripNoOpText(at: idx, in: &state.messages)
                }
                state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                state.needsNewMessage = false
            } else if state.messages.last?.role != .assistant || !(state.messages.last?.isStreaming ?? false) {
                state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
            }
            if let lastIndex = state.messages.indices.last,
               state.messages[lastIndex].role == .assistant
            {
                state.messages[lastIndex].appendToolCall(ToolCall(id: id, name: name, input: [:]))
            }
            // Ready to receive the arguments
            state.activeToolId = id
            state.activeToolInputBuffer = ""
        }
        shellTrackerUpsertToolSpan(id: id, name: name, input: [:], sessionKey: sessionKey)
    }

    /// Attach a tool call's complete arguments and run the side effects that
    /// depend on them — the pre-edit file snapshot and TodoWrite extraction.
    func applyToolCallInput(id toolId: String, input: [String: JSONValue], for sessionKey: String) {
        var todos: [TodoItem]?
        var spanUpdate: (name: String, input: [String: JSONValue])?
        updateState(sessionKey) { state in
            if state.activeToolId == toolId {
                state.activeToolId = nil
                state.activeToolInputBuffer = ""
            }
            guard let msgIdx = state.messages.indices.reversed().first(where: {
                state.messages[$0].role == .assistant && state.messages[$0].toolCallIndex(id: toolId) != nil
            }), let blockIdx = state.messages[msgIdx].toolCallIndex(id: toolId) else { return }

            var merged = state.messages[msgIdx].blocks[blockIdx].toolCall?.input ?? [:]
            for (k, v) in input {
                merged[k] = v
            }
            state.messages[msgIdx].blocks[blockIdx].toolCall?.input = merged
            guard let toolCall = state.messages[msgIdx].blocks[blockIdx].toolCall else { return }
            let toolName = toolCall.name
            if toolCall.result == nil {
                spanUpdate = (toolName, merged)
            }

            // Kick off the pre-edit file snapshot now that the tool input (and
            // therefore `file_path`) is finally known. ACP runtimes hit
            // `captureEditingFileSnapshot` from their `.assistant` block; the
            // Claude streaming path never delivers `file_path` until the
            // arguments finish, so this is the earliest point it can run.
            Self.captureEditingFileSnapshot(toolName: toolName, input: merged, state: &state)

            if toolName.lowercased() == "todowrite" {
                todos = TodoExtractor.parse(input: merged)
            }
        }

        if let spanUpdate {
            shellTrackerUpsertToolSpan(id: toolId, name: spanUpdate.name, input: spanUpdate.input, sessionKey: sessionKey)
        }

        if let todos {
            let done = todos.filter { $0.status == .completed }.count
            let active = todos.first(where: { $0.status == .inProgress })?.activeForm ?? "-"
            logger.info(
                "[TodoWrite] session=\(sessionKey, privacy: .public) total=\(todos.count) done=\(done) active=\(active, privacy: .public)"
            )
            recordTodoSnapshot(todos, forSessionId: sessionKey)
        }
    }

    // MARK: - Cancel

    func detachCurrentStream(in window: WindowState) {
        let key = window.currentSessionId ?? window.newSessionKey
        flushPendingUpdates(for: key, forceText: true)
        stopFlushTimer(for: key)
    }

    /// - Parameter fireStopHooks: When `true` (explicit Stop button), the
    ///   session-stop hooks fire because streaming genuinely stopped. When
    ///   `false` (the user sent a *new* message that interrupts the current
    ///   stream), the session isn't stopping — a new turn starts immediately —
    ///   so the stop hooks are skipped. The cancelled stream is still marked
    ///   handled either way so a trailing `.result` can't re-fire them.
    func cancelStreaming(in window: WindowState, fireStopHooks: Bool = true) async {
        let key = window.currentSessionId ?? window.newSessionKey
        usageLimitResumeTasks.removeValue(forKey: key)?.cancel()
        let streamToCancel = sessionStates[key]?.activeStreamId
        sessionStates[key]?.streamTask?.cancel()

        // Finalize the in-progress turn *before* the await below, in a single
        // state mutation. The session `isStreaming` flag and the streaming
        // message's own `isStreaming` flag must flip to false together: if they
        // disagree when the message list rebuilds (which is driven by the
        // session flag), the paused bubble lands in neither the settled list
        // nor the streaming view and vanishes until the next turn. Clearing
        // isStreaming here also stops processStream's end-of-stream cleanup
        // from re-finalizing the cancelled message while we suspend.
        flushPendingUpdates(for: key, forceText: true)
        stopFlushTimer(for: key)

        updateState(key) { state in
            state.isStreaming = false
            state.isThinking = false
            state.needsNewMessage = false
            state.activeStreamId = nil
            state.streamTask = nil
            state.activeToolId = nil
            state.activeToolInputBuffer = ""
            state.textDeltaBuffer = ""
            state.pendingToolResults.removeAll()
            state.computerUseWindows.removeAll()
            state.lastStreamEventDate = nil
            state.liveBackgroundTaskIds.removeAll()
            state.unconsumedSteerCount = 0
            for idx in state.messages.indices where state.messages[idx].role == .assistant {
                let hasPendingTool = state.messages[idx].blocks.contains {
                    guard let tc = $0.toolCall else { return false }
                    return tc.result == nil && !tc.isKeepAlways
                }
                guard state.messages[idx].isStreaming || hasPendingTool else { continue }
                // The user paused this turn — keep the partial assistant bubble
                // visible. markStreamInterrupted() clears the message's streaming
                // flag and retains in-progress tool calls (flagged as interrupted)
                // instead of dropping them; the no-op strip below is told not to
                // delete an emptied message.
                let wasStreamingBubble = state.messages[idx].isStreaming
                state.messages[idx].markStreamInterrupted()
                if wasStreamingBubble, let start = state.streamingStartDate {
                    state.messages[idx].duration = Date().timeIntervalSince(start)
                }
                Self.stripNoOpText(at: idx, in: &state.messages, removeIfEmpty: false)
            }
            state.streamingStartDate = nil
            state.inFlightUserAttachments = []
        }

        window.showError = false
        window.errorMessage = nil

        // A backend can already have withdrawn its approval when its stream task was cancelled.
        let displayedPermissionIds = mobilePendingRequests.values.filter { $0.sessionId == key }.map(\.id)
        let cancelledPermissionIds = await permission.cancelPending(sessionId: key)
        clearAutoResolvedPermissions(displayedPermissionIds + cancelledPermissionIds)

        if let streamToCancel {
            let provider = sessionStates[key]?.agentProvider ?? effectiveModelSelection(in: window).provider
            await backend(for: provider).cancel(streamId: streamToCancel)
        }

        await awaitPendingShellDetections(for: key)

        // Save messages accumulated up to the point of cancellation to disk (prevent data loss).
        // The placeholder session (if any) is left in place so partial messages remain visible;
        // it will be promoted to the real CLI session id on the next user turn.
        if let project = window.selectedProject {
            // Cancelling is also "streaming stops" — fire the stop hooks, guarded
            // by the same per-stream set so a trailing `.result` won't re-run them.
            // Before-stop runs ahead of the save so its cards persist; after-stop
            // runs post-save and is shown only.
            let alreadyHandled = streamToCancel.map { stopHooksHandledStreamIds.contains($0) } ?? true
            // Mark the stream handled regardless of `fireStopHooks` so a
            // trailing `.result` event can't re-fire the stop hooks later.
            if let streamToCancel, !alreadyHandled {
                stopHooksHandledStreamIds.insert(streamToCancel)
            }
            if fireStopHooks, streamToCancel != nil, !alreadyHandled {
                _ = await hookManager.dispatchBeforeSessionEnd(SessionEndPayload(
                    project: project,
                    sessionKey: key,
                    sessionId: key,
                    reason: .cancelled,
                    turnDidError: false,
                    lastAssistantText: lastAssistantResponseText(in: stateForSession(key).messages)
                ))
            }
            let messages = stateForSession(key).messages
            if !messages.isEmpty {
                await saveSession(sessionId: key, projectId: project.id, messages: messages)
            }
            if fireStopHooks, streamToCancel != nil, !alreadyHandled {
                _ = await hookManager.dispatchAfterSessionEnd(SessionEndPayload(
                    project: project,
                    sessionKey: key,
                    sessionId: key,
                    reason: .cancelled,
                    turnDidError: false,
                    lastAssistantText: lastAssistantResponseText(in: stateForSession(key).messages)
                ))
            }
        }
    }

    func recordStreamingDuration(for key: String) {
        guard let start = sessionStates[key]?.streamingStartDate else { return }
        let duration = Date().timeIntervalSince(start)
        updateState(key) { state in
            state.streamingStartDate = nil
            if let idx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant }) {
                state.messages[idx].duration = duration
            }
        }
    }

    // MARK: - Permission Response

    func respondToPermission(_ request: PermissionRequest, decision: PermissionDecision, in window: WindowState) async {
        let autoResolvedIds = await permission.respond(toolUseId: request.id, decision: decision)
        window.pendingPermissions.removeAll { $0.id == request.id }
        mobilePendingRequests.removeValue(forKey: request.id)
        if let sessionId = request.sessionId {
            broadcastMobileSessionStatus(sessionID: sessionId)
        }
        clearAutoResolvedPermissions(autoResolvedIds + [request.id])

        // Fan the resolved decision out to hooks. Dispatching here (rather than at
        // each UI button) means desktop and mobile responses both fire exactly once.
        let payload = PermissionDecisionPayload(
            toolUseId: request.id,
            toolName: request.toolName,
            sessionId: request.sessionId,
            projectId: window.selectedProject?.id,
            decision: Self.permissionDecisionLabel(decision)
        )
        if Self.permissionDecisionIsApproval(decision) {
            await hookManager.dispatchPermissionApprove(payload)
        } else {
            await hookManager.dispatchPermissionDenied(payload)
        }
    }

    /// Remove requests the PermissionServer resolved as a side effect of a broad grant
    /// (session tool allow, Bash allowlist, switch to auto) from every window's queue,
    /// so the user is not prompted again for calls that were already queued.
    func clearAutoResolvedPermissions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        for window in registeredWindows() {
            window.pendingPermissions.removeAll { idSet.contains($0.id) }
            if let presented = window.presentedPermissionId, idSet.contains(presented) {
                window.presentedPermissionId = nil
            }
        }
        var sessionIds = Set<String>()
        for id in ids {
            if let sessionId = mobilePendingRequests.removeValue(forKey: id)?.sessionId {
                sessionIds.insert(sessionId)
            }
        }
        for sessionId in sessionIds {
            broadcastMobileSessionStatus(sessionID: sessionId)
        }
    }

    /// Stable, serializable label for a permission decision (for hook payloads).
    static func permissionDecisionLabel(_ decision: PermissionDecision) -> String {
        switch decision {
        case .allow: return "allow"
        case .deny: return "deny"
        case .allowSessionTool: return "allowSessionTool"
        case .allowAlwaysCommand: return "allowAlwaysCommand"
        case .allowAndSetMode: return "allowAndSetMode"
        case .denyWithReason: return "denyWithReason"
        }
    }

    /// Whether a decision grants the tool call (vs. denies it).
    static func permissionDecisionIsApproval(_ decision: PermissionDecision) -> Bool {
        switch decision {
        case .allow, .allowSessionTool, .allowAlwaysCommand, .allowAndSetMode:
            return true
        case .deny, .denyWithReason:
            return false
        }
    }

    // MARK: - AskUserQuestion Response

    /// Deliver the user's answers for an AskUserQuestion tool call via the PreToolUse hook.
    ///
    /// AskUserQuestion is handled like any other PreToolUse hook: the PermissionServer is
    /// holding the HTTP connection open waiting for a decision. We resolve it with `allow` +
    /// `updatedInput: {questions, answers: {questionText: <answerValue>}}` so the CLI injects
    /// the answers into the tool input and proceeds.
    func respondToAskUserQuestion(
        toolUseId: String,
        answers: [Int: AskUserQuestion.Answer],
        in window: WindowState
    ) async {
        let key = window.currentSessionId ?? window.newSessionKey
        let turnEnded = !isSessionTurnRunning(key)
        var followUp: String?

        var updatedInput = JSONValue.object([
            "questions": .array([]),
            "answers": .object([:]),
        ])

        updateState(key) { state in
            for i in state.messages.indices.reversed() {
                guard let idx = state.messages[i].toolCallIndex(id: toolUseId),
                      let toolInput = state.messages[i].blocks[idx].toolCall?.input,
                      let parsed = AskUserQuestion(input: toolInput) else { continue }

                updatedInput = AskUserQuestion.updatedInputJSON(
                    originalInput: toolInput,
                    questions: parsed.questions,
                    answers: answers
                )
                let summary = AskUserQuestion.summary(questions: parsed.questions, answers: answers)
                state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                followUp = AskUserQuestion.followUpPrompt(questions: parsed.questions, answers: answers)
                return
            }
        }

        // Polyfill questions (`ide__ask_user`) have no matching chat tool call —
        // build the answer payload from the queued request's input instead.
        if updatedInput["answers"]?.objectValue?.isEmpty ?? true,
           let request = window.pendingPermissions.first(where: { $0.id == toolUseId })
               ?? mobilePendingRequests[toolUseId],
           let parsed = AskUserQuestion(input: request.toolInput) {
            updatedInput = AskUserQuestion.updatedInputJSON(
                originalInput: request.toolInput,
                questions: parsed.questions,
                answers: answers
            )
            followUp = AskUserQuestion.followUpPrompt(questions: parsed.questions, answers: answers)
        }

        window.pendingPermissions.removeAll { $0.id == toolUseId }
        let requestSessionId = mobilePendingRequests.removeValue(forKey: toolUseId)?.sessionId
        if window.presentedPermissionId == toolUseId {
            window.presentedPermissionId = nil
        }
        if let requestSessionId {
            broadcastMobileSessionStatus(sessionID: requestSessionId)
        }
        broadcastMobileQuestionQueue()

        await permission.respondAskUserQuestion(toolUseId: toolUseId, updatedInput: updatedInput)

        // The turn that asked already ended, so nothing reads the tool result —
        // send the answers as a new message to continue the thread.
        if turnEnded, let followUp, !followUp.isEmpty {
            await sendLatePromptAnswer(followUp, sessionKey: key)
        }
    }

    /// User dismissed the question sheet without answering — resolve the hook as deny so
    /// the CLI does not block, and clear the pending entry from the window queue.
    func skipAskUserQuestion(toolUseId: String, in window: WindowState) async {
        window.pendingPermissions.removeAll { $0.id == toolUseId }
        let requestSessionId = mobilePendingRequests.removeValue(forKey: toolUseId)?.sessionId
        if window.presentedPermissionId == toolUseId {
            window.presentedPermissionId = nil
        }
        if let requestSessionId {
            broadcastMobileSessionStatus(sessionID: requestSessionId)
        }
        broadcastMobileQuestionQueue()
        await permission.respond(toolUseId: toolUseId, decision: .deny)
    }

    /// Apply a question answer that arrived from a paired mobile device.
    /// Resolves the CLI hook, mirrors the answer into chat history, and clears
    /// the request from every desktop window's queue. An empty `answers` array
    /// means the user chose "Skip All Questions" on mobile.
    func handleMobileQuestionAnswer(_ payload: QuestionAnswerPayload) async {
        let toolUseId = payload.toolUseID
        guard let request = mobilePendingRequests[toolUseId] else { return }

        guard !payload.answers.isEmpty, let parsed = AskUserQuestion(input: request.toolInput) else {
            // Skip — or a malformed payload we cannot answer: deny the hook.
            clearPendingQuestion(toolUseId: toolUseId, sessionId: request.sessionId)
            await permission.respond(toolUseId: toolUseId, decision: .deny)
            return
        }

        var answers: [Int: AskUserQuestion.Answer] = [:]
        for entry in payload.answers {
            answers[entry.questionIndex] = entry.multiSelect
                ? .multi(entry.values)
                : .single(entry.values.first ?? "")
        }

        let updatedInput = AskUserQuestion.updatedInputJSON(
            originalInput: request.toolInput,
            questions: parsed.questions,
            answers: answers
        )
        let summary = AskUserQuestion.summary(questions: parsed.questions, answers: answers)
        let turnEnded = request.sessionId.map { !isSessionTurnRunning($0) } ?? false

        if let sessionId = request.sessionId {
            updateState(sessionId) { state in
                for i in state.messages.indices.reversed() {
                    guard state.messages[i].toolCallIndex(id: toolUseId) != nil else { continue }
                    state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                    return
                }
            }
        }

        clearPendingQuestion(toolUseId: toolUseId, sessionId: request.sessionId)
        await permission.respondAskUserQuestion(toolUseId: toolUseId, updatedInput: updatedInput)

        if turnEnded, let sessionId = request.sessionId {
            let followUp = AskUserQuestion.followUpPrompt(questions: parsed.questions, answers: answers)
            if !followUp.isEmpty {
                await sendLatePromptAnswer(followUp, sessionKey: sessionId)
            }
        }
    }

    /// Apply a plan decision that arrived from a paired mobile device. Builds a
    /// transient `WindowState` bound to the target session — mirroring
    /// `handleMobileUserMessage` — and delegates to `respondToPlanDecision`,
    /// which owns all the desktop plan logic (CLI hook release, decision summary
    /// into `toolCall.result` + `planDecisionSummaries`, `threadStore` persist,
    /// one-shot plan-mode clear, follow-up permission mode, continuation prompt).
    /// The updated messages broadcast back through the normal session-update sync.
    func handleMobilePlanDecision(_ payload: PlanDecisionPayload) async {
        let sessionID = resolveCurrentSessionId(payload.sessionID)
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            logger.error("[MobileSync] plan decision for unknown thread=\(payload.sessionID, privacy: .public)")
            return
        }
        let window = WindowState()
        window.selectedProject = projects.first(where: { $0.id == summary.projectId })
        window.currentSessionId = sessionID
        // `respondToPlanDecision` reads `window.sessionPlanMode` to clear plan
        // mode one-shot and `window.sessionPermissionMode` for re-registration —
        // mirror the live session state into the fresh window.
        if let state = sessionStates[sessionID] {
            window.sessionPlanMode = state.planMode
            window.sessionPermissionMode = state.permissionMode
        }
        await respondToPlanDecision(
            toolUseId: payload.toolUseID,
            action: payload.toDecisionAction(),
            in: window
        )
    }

    /// Remove a resolved `AskUserQuestion` request from every window's queue and
    /// re-broadcast the (now smaller) queue to mobile.
    func clearPendingQuestion(toolUseId: String, sessionId: String?) {
        for window in registeredWindows() {
            window.pendingPermissions.removeAll { $0.id == toolUseId }
            if window.presentedPermissionId == toolUseId {
                window.presentedPermissionId = nil
            }
        }
        mobilePendingRequests.removeValue(forKey: toolUseId)
        if let sessionId {
            broadcastMobileSessionStatus(sessionID: sessionId)
        }
        broadcastMobileQuestionQueue()
    }
}
