import Foundation
import RxCodeChatKit
import RxCodeCore

extension AppState {
    func canSteer(in window: WindowState) -> Bool {
        canSteer(sessionID: queueKey(for: window), fallbackProvider: effectiveModelSelection(in: window).provider)
    }

    func canSteer(sessionID: String, fallbackProvider: AgentProvider) -> Bool {
        let state = stateForSession(sessionID)
        let backend = backend(for: state.agentProvider ?? fallbackProvider)
        if backend is ACPService {
            return state.isStreaming && state.activeStreamId != nil && state.acpSteeringStreamId == state.activeStreamId
        }
        return backend.supportsSteering
    }

    func steerActiveStream(text: String, attachments: [Attachment], in window: WindowState) async -> Bool {
        guard let project = window.selectedProject else { return false }
        return await steerActiveStream(
            text: text, attachments: attachments, sessionID: queueKey(for: window), projectID: project.id,
            fallbackProvider: effectiveModelSelection(in: window).provider
        )
    }

    private func steerActiveStream(
        text: String, attachments: [Attachment], sessionID: String, projectID: UUID, fallbackProvider: AgentProvider
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = stateForSession(sessionID)
        guard state.isStreaming, let streamId = state.activeStreamId,
              !trimmed.isEmpty || !attachments.isEmpty else { return false }
        let resolved = AttachmentFactory.resolvingClipboardImages(attachments).resolved
        let message = ChatMessage(role: .user, content: text, attachments: resolved)
        let prompt = buildPromptWithAttachments(trimmed, attachments: resolved)
        let provider = state.agentProvider ?? fallbackProvider
        let backend = backend(for: provider)

        if let service = backend as? ACPService {
            let outcome = await service.steer(streamId: streamId, prompt: prompt, message: message)
            guard outcome != .declined else { return false }
            let key = resolveCurrentSessionId(sessionID)
            // The ordered stream event usually commits the message. A Stop
            // can detach its consumer while the ACP request is still in flight.
            if stateForSession(key).activeStreamId != streamId {
                recordACPSteeredMessage(message, confirmed: outcome == .injected, sessionID: key)
                await saveSession(sessionId: key, projectId: projectID, messages: stateForSession(key).messages)
            }
            return true
        }

        guard await backend.steer(streamId: streamId, prompt: prompt) else { return false }
        let key = resolveCurrentSessionId(sessionID)
        flushPendingUpdates(for: key, forceText: true)
        updateState(key) { state in
            state.messages.append(message)
            if state.activeStreamId == streamId {
                state.needsNewMessage = true
                if provider == .claudeCode { state.unconsumedSteerCount += 1 }
            }
        }
        await CodingAnalyticsRecorder.shared.update(turnID: streamId, prompt: text)
        await saveSession(sessionId: key, projectId: projectID, messages: stateForSession(key).messages)
        return true
    }

    func recordACPSteeredMessage(_ message: ChatMessage, confirmed: Bool, sessionID: String) {
        guard !stateForSession(sessionID).messages.contains(where: { $0.id == message.id }) else { return }
        flushPendingUpdates(for: sessionID, forceText: true)
        updateState(sessionID) { state in
            if let index = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                state.messages[index].isStreaming = false
            }
            state.messages.append(message)
            state.needsNewMessage = false
            if !confirmed {
                state.messages.append(ChatMessage(
                    role: .assistant,
                    content: "The ACP client didn’t confirm delivery of this instruction. Check the response before sending it again.",
                    isError: true
                ))
            }
        }
    }

    @discardableResult
    func steerQueuedMessage(id: UUID, in window: WindowState) async -> Bool {
        guard let target = window.messageQueue.first(where: { $0.id == id }),
              let project = window.selectedProject else { return false }
        return await steerQueuedMessages(
            [target], sessionID: queueKey(for: window), projectID: project.id,
            fallbackProvider: effectiveModelSelection(in: window).provider, sourceWindow: window
        )
    }

    @discardableResult
    func steerAllQueuedAsOne(in window: WindowState) async -> Bool {
        guard let project = window.selectedProject else { return false }
        return await steerQueuedMessages(
            window.messageQueue, sessionID: queueKey(for: window), projectID: project.id,
            fallbackProvider: effectiveModelSelection(in: window).provider, sourceWindow: window
        )
    }

    func steerQueuedMessages(
        _ messages: [QueuedMessage], sessionID: String, projectID: UUID, fallbackProvider: AgentProvider,
        sourceWindow: WindowState? = nil
    ) async -> Bool {
        guard !messages.isEmpty, beginQueueDispatch(sessionID: sessionID) else { return false }
        defer { endQueueDispatch(sessionID: sessionID) }
        let text = combinedQueuedText(messages)
        guard await steerActiveStream(
            text: text, attachments: messages.flatMap(\.attachments), sessionID: sessionID, projectID: projectID,
            fallbackProvider: fallbackProvider
        ) else { return false }
        removeDispatchedMessages(messages, sessionID: sessionID, sourceWindow: sourceWindow)
        return true
    }

    func combinedQueuedText(_ messages: [QueuedMessage]) -> String {
        messages.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    func beginQueueDispatch(sessionID: String, requiresActiveTurn: Bool = true) -> Bool {
        let state = stateForSession(sessionID)
        guard !state.queueDispatchInProgress, state.isStreaming || !requiresActiveTurn else { return false }
        updateState(sessionID) { $0.queueDispatchInProgress = true }
        return true
    }

    func endQueueDispatch(sessionID: String) {
        let key = resolveCurrentSessionId(sessionID)
        let needsFlush = stateForSession(key).queueFlushDeferred
        updateState(key) {
            $0.queueDispatchInProgress = false
            $0.queueFlushDeferred = false
        }
        if needsFlush {
            Task { await flushNextQueuedMessageIfNeeded(sessionID: key) }
        }
    }

    func removeDispatchedMessages(_ messages: [QueuedMessage], sessionID: String, sourceWindow: WindowState?) {
        let key = resolveCurrentSessionId(sessionID)
        for message in messages {
            threadStore.removeQueued(id: message.id)
            evictFromWindowQueueMirrors(sessionID: key, queuedID: message.id)
        }
        if let sourceWindow, queueKey(for: sourceWindow) == key {
            let ids = Set(messages.map(\.id))
            sourceWindow.messageQueue.removeAll { ids.contains($0.id) }
            saveQueue(in: sourceWindow)
        }
        broadcastMobileSessionStatus(sessionID: key)
    }
}
