import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Text Delta Throttle (50ms)

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

    func flushPendingUpdates(for key: String) {
        guard var state = sessionStates[key] else { return }

        let hasText = !state.textDeltaBuffer.isEmpty
        let hasToolResults = !state.pendingToolResults.isEmpty

        guard hasText || hasToolResults else { return }

        let prevMessages = state.messages

        func lastAssistantIdx() -> Int? {
            state.messages.indices.reversed().first { state.messages[$0].role == .assistant }
        }
        func lastStreamingAssistantIdx() -> Int? {
            state.messages.indices.reversed().first { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }
        }

        // 1. Tool results — apply to the current streaming assistant message
        if hasToolResults {
            let results = state.pendingToolResults
            state.pendingToolResults.removeAll(keepingCapacity: true)
            if let idx = lastAssistantIdx() {
                for (toolUseId, content, isError) in results {
                    let editPersistInfos: [(path: String, hunks: [PreviewFile.EditHunk], isWrite: Bool)] = {
                        guard !isError,
                              let blockIdx = state.messages[idx].toolCallIndex(id: toolUseId),
                              let call = state.messages[idx].blocks[blockIdx].toolCall,
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
                        guard let blockIdx = state.messages[idx].toolCallIndex(id: toolUseId),
                              let call = state.messages[idx].blocks[blockIdx].toolCall,
                              Self.isExitPlanModeCall(call),
                              let existing = call.result else { return false }
                        return Self.planDecisionResultPrefixes.contains { existing.hasPrefix($0) }
                    }()
                    if !skipResultOverwrite {
                        state.messages[idx].setToolResult(id: toolUseId, result: content, isError: isError)
                    }
                    if !editPersistInfos.isEmpty {
                        for info in editPersistInfos {
                            threadStore.appendFileEdit(
                                sessionId: key,
                                path: info.path,
                                hunks: info.hunks,
                                containsWrite: info.isWrite
                            )
                        }
                        threadFileEditsRevision &+= 1
                    }
                }
            }
        }

        // 2. Text delta flush
        if hasText {
            let buffered = state.textDeltaBuffer
            state.textDeltaBuffer = ""
            if let idx = lastStreamingAssistantIdx() {
                if state.needsNewMessage {
                    // New Claude turn after receiving tool result — start a new ChatMessage
                    state.messages[idx].isStreaming = false
                    state.messages[idx].finalizeToolCalls()
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
                let toolCall = ToolCall(id: id, name: name, input: [:])
                // Flush the text buffer first so text blocks are committed before tools
                flushPendingUpdates(for: sessionKey)
                updateState(sessionKey) { state in
                    state.isThinking = false
                    // needsNewMessage: new Claude turn after tool result — create a new ChatMessage
                    if state.needsNewMessage {
                        if let idx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }) {
                            state.messages[idx].isStreaming = false
                            state.messages[idx].finalizeToolCalls()
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
                        state.messages[lastIndex].appendToolCall(toolCall)
                    }
                    // Ready to receive input_json_delta
                    state.activeToolId = id
                    state.activeToolInputBuffer = ""
                }
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
                updateState(sessionKey) { state in
                    state.isThinking = false
                    state.textDeltaBuffer += text
                }
            } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                updateState(sessionKey) { state in
                    state.activeToolInputBuffer += partial
                }
            } else if deltaType == "thinking_delta" {
                updateState(sessionKey) { $0.isThinking = true }
            }

        case "content_block_stop":
            // Finalize tool_use input — parse the accumulated JSON and apply to the tool call
            updateState(sessionKey) { state in
                guard let toolId = state.activeToolId, !state.activeToolInputBuffer.isEmpty else {
                    state.activeToolId = nil
                    return
                }
                let buffer = state.activeToolInputBuffer
                state.activeToolId = nil
                state.activeToolInputBuffer = ""

                guard let inputData = buffer.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: inputData) else { return }

                if let msgIdx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }),
                   let blockIdx = state.messages[msgIdx].toolCallIndex(id: toolId)
                {
                    state.messages[msgIdx].blocks[blockIdx].toolCall?.input = parsed
                    if let toolName = state.messages[msgIdx].blocks[blockIdx].toolCall?.name,
                       toolName.lowercased() == "todowrite"
                    {
                        let todos = TodoExtractor.parse(input: parsed)
                        let done = todos.filter { $0.status == .completed }.count
                        let active = todos.first(where: { $0.status == .inProgress })?.activeForm ?? "-"
                        logger.info(
                            "[TodoWrite] session=\(sessionKey, privacy: .public) total=\(todos.count) done=\(done) active=\(active, privacy: .public)"
                        )
                        threadStore.upsertTodoSnapshot(sessionId: sessionKey, items: todos)
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Cancel

    func detachCurrentStream(in window: WindowState) {
        let key = window.currentSessionId ?? window.newSessionKey
        flushPendingUpdates(for: key)
        stopFlushTimer(for: key)
    }

    func cancelStreaming(in window: WindowState) async {
        let key = window.currentSessionId ?? window.newSessionKey
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
        flushPendingUpdates(for: key)
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
            if let idx = state.messages.indices.reversed().first(where: {
                state.messages[$0].role == .assistant && state.messages[$0].isStreaming
            }) {
                // The user paused this turn — keep the partial assistant bubble
                // visible. markStreamInterrupted() clears the message's streaming
                // flag and retains in-progress tool calls (flagged as interrupted)
                // instead of dropping them; the no-op strip below is told not to
                // delete an emptied message.
                state.messages[idx].markStreamInterrupted()
                if let start = state.streamingStartDate {
                    state.messages[idx].duration = Date().timeIntervalSince(start)
                }
                Self.stripNoOpText(at: idx, in: &state.messages, removeIfEmpty: false)
            }
            state.streamingStartDate = nil
            state.inFlightUserAttachments = []
        }

        window.showError = false
        window.errorMessage = nil

        if let streamToCancel {
            let provider = sessionStates[key]?.agentProvider ?? effectiveModelSelection(in: window).provider
            await backend(for: provider).cancel(streamId: streamToCancel)
        }

        // Save messages accumulated up to the point of cancellation to disk (prevent data loss).
        // The placeholder session (if any) is left in place so partial messages remain visible;
        // it will be promoted to the real CLI session id on the next user turn.
        if let project = window.selectedProject {
            let messages = stateForSession(key).messages
            if !messages.isEmpty {
                await saveSession(sessionId: key, projectId: project.id, messages: messages)
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
        await permission.respond(toolUseId: request.id, decision: decision)
        window.pendingPermissions.removeAll { $0.id == request.id }
        mobilePendingRequests.removeValue(forKey: request.id)
        if let sessionId = request.sessionId {
            broadcastMobileSessionStatus(sessionID: sessionId)
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
                return
            }
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

    // MARK: - Plan Decision Response

    /// Resolve a Claude `ExitPlanMode` tool call based on the user's choice in the plan card.
    /// Drives both the PermissionServer hook response (allow/deny + optional reason or
    /// follow-up mode change) and the local UI bookkeeping (clear plan-mode pill, update
    /// permission chip, mark the tool block decided).
    func respondToPlanDecision(toolUseId: String, action: PlanDecisionAction, in window: WindowState) async {
        let summary: String
        let decision: PermissionDecision
        let nextMode: PermissionMode?

        switch action {
        case .acceptAsk:
            summary = "Accepted with Ask"
            decision = .allowAndSetMode(newMode: .default)
            nextMode = .default
        case .acceptWithEdits:
            summary = "Accepted with Edits"
            decision = .allowAndSetMode(newMode: .acceptEdits)
            nextMode = .acceptEdits
        case .acceptAutoApprove:
            summary = "Accepted with Auto-approve"
            decision = .allowAndSetMode(newMode: .auto)
            nextMode = .auto
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            summary = trimmed.isEmpty ? "Rejected" : "Rejected: \(trimmed)"
            decision = .denyWithReason(reason: trimmed.isEmpty ? "User rejected the plan." : trimmed)
            nextMode = nil
        case .reject:
            summary = "Rejected"
            decision = .denyWithReason(reason: "User rejected the plan.")
            nextMode = nil
        }

        // Record the outcome on the tool block so `PlanCardView` flips from buttons to
        // a "decided" status row. This mirrors how AskUserQuestionView reads `toolCall.result`.
        // Also write into a sidecar dict that survives CLI-backed session reloads —
        // the CLI emits its own follow-up tool_result ("User has approved your plan…")
        // that overwrites `ToolCall.result` once the session jsonl is parsed fresh
        // from disk, so the in-memory result alone is not reliable.
        let key = window.currentSessionId ?? window.newSessionKey
        updateState(key) { state in
            for i in state.messages.indices.reversed() {
                if state.messages[i].toolCallIndex(id: toolUseId) != nil {
                    state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                    break
                }
            }
            state.planDecisionSummaries[toolUseId] = summary
        }
        threadStore.setPlanDecision(sessionId: key, toolCallId: toolUseId, summary: summary)

        // Plan-mode is one-shot — clear the pill so the next user turn isn't in plan mode.
        // This also triggers a permission re-register (no-op if there's no live CLI sid).
        if window.sessionPlanMode {
            window.sessionPlanMode = false
            updateState(key) { $0.planMode = false }
        }

        // Persist the new permission mode in the dropdown when the user opted for a
        // follow-up mode change. `setSessionPermissionMode` also re-registers with the
        // PermissionServer for the live session.
        if let nextMode {
            setSessionPermissionMode(nextMode, in: window)
        } else {
            // Even when no mode change is requested, re-register so the server registry
            // reflects the now-cleared plan-mode boolean.
            reregisterPermissionMode(in: window)
        }

        await permission.respond(toolUseId: toolUseId, decision: decision)

        // When the CLI honors `allowAndSetMode` it continues the same turn — the model
        // executes (or revises) the plan inline and the turn ends naturally. In that
        // case sending a follow-up prompt would spawn a redundant second turn that
        // reports "the work is already done". Only inject a continuation message when
        // the turn actually ended without producing any post-plan content, mirroring
        // the older CLI behavior where ExitPlanMode terminated the turn outright.
        let continuationPrompt = Self.continuationPrompt(for: action)

        if let continuationPrompt {
            if let task = sessionStates[key]?.streamTask {
                _ = await task.value
            }
            if turnContinuedAfterPlan(toolUseId: toolUseId, sessionKey: key) {
                return
            }
            await sendPrompt(
                continuationPrompt,
                skipAppendingUserMessage: true,
                in: window
            )
        }
    }

    /// True when the assistant actually *executed* the plan after the given
    /// ExitPlanMode tool call — i.e. the CLI invoked at least one other tool
    /// (Edit / Write / Bash / etc.) in the same turn, so a follow-up
    /// "Proceed with the plan." would just spawn a redundant turn. Used to
    /// gate the hidden continuation prompt.
    ///
    /// Text-only post-plan content (a brief preamble, or a recap of the plan
    /// the model already wrote into a file) does NOT count — that's the stall
    /// mode where the user is left waiting and we *do* want to inject the
    /// nudge so implementation actually starts.
    func turnContinuedAfterPlan(toolUseId: String, sessionKey: String) -> Bool {
        guard let messages = sessionStates[sessionKey]?.messages else { return false }
        for messageIdx in messages.indices.reversed() {
            guard let planBlockIdx = messages[messageIdx].toolCallIndex(id: toolUseId) else {
                continue
            }
            // Same message: any tool-call block after the plan block counts as work.
            let trailingBlocks = messages[messageIdx].blocks.dropFirst(planBlockIdx + 1)
            if trailingBlocks.contains(where: { $0.toolCall != nil }) {
                return true
            }
            // Subsequent assistant messages: any tool-call block at all.
            if messageIdx + 1 < messages.count {
                for later in messages[(messageIdx + 1)...] where later.role == .assistant {
                    if later.blocks.contains(where: { $0.toolCall != nil }) {
                        return true
                    }
                }
            }
            return false
        }
        return false
    }

    /// Prefixes of result strings written by `respondToPlanDecision`. Sourced from
    /// `PlanDecisionAction.userDecisionResultPrefixes` so the chip in chat, the
    /// CLI-session reload guard, and the live-stream guard all share one source
    /// of truth.
    static let planDecisionResultPrefixes: [String] = PlanDecisionAction.userDecisionResultPrefixes

    static func isExitPlanModeCall(_ call: ToolCall) -> Bool {
        let n = call.name.lowercased()
        return n == "exitplanmode" || n == "exit_plan_mode"
    }

    /// Hidden follow-up prompt to send after a plan decision, or nil if the chat
    /// should stop. Plain `.reject` returns nil; `.rejectWithFeedback` with empty
    /// feedback also returns nil (the user effectively did a plain reject).
    static func continuationPrompt(for action: PlanDecisionAction) -> String? {
        switch action {
        case .acceptAsk, .acceptWithEdits, .acceptAutoApprove:
            return "Proceed with the plan."
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? nil
                : "Revise the plan based on this feedback: \(trimmed)"
        case .reject:
            return nil
        }
    }

}
