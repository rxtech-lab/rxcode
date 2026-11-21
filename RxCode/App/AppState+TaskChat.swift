import Foundation
import os
import RxCodeCore

extension AppState {
    // MARK: - Chat navigation

    /// Opens the chat thread a task was dispatched into. Returns `false` when
    /// the task has never run or its thread no longer exists.
    @discardableResult
    func openChat(for task: ProjectTask, in window: WindowState) -> Bool {
        guard let sessionId = chatSessionId(for: task) else {
            logger.error("[Tasks] no chat thread found for task \(task.id.uuidString, privacy: .public) key=\(task.sessionKey ?? "<nil>", privacy: .public)")
            return false
        }
        selectSession(id: sessionId, in: window)
        return true
    }

    /// Whether `openChat` can reveal a thread for this task. Surfaces use it to
    /// hide Open Chat rather than offer a button that does nothing.
    func canOpenChat(for task: ProjectTask) -> Bool {
        chatSessionId(for: task) != nil
    }

    func chatSessionId(for task: ProjectTask) -> String? {
        guard let key = task.sessionKey else { return nil }
        let sessionId = resolveCurrentSessionId(key)
        return allSessionSummaries.contains(where: { $0.id == sessionId }) ? sessionId : nil
    }

    /// True while the task's linked thread is mid-turn.
    ///
    /// Reads `sessionActivity` rather than `sessionStates` because every card
    /// on the board asks this in its body, and `sessionStates` is mutated many
    /// times per stream event (see `AppState+SessionActivity.swift`). The
    /// session-id redirect is resolved so a task still linked to its
    /// `pending-…` placeholder key matches the renamed CLI session.
    func isAgentRunning(for task: ProjectTask) -> Bool {
        guard let key = task.sessionKey else { return false }
        return sessionActivity[resolveCurrentSessionId(key)]?.isStreaming ?? false
    }

    /// True while any task under `story` has a running thread, so a story card
    /// can show the same spinner its children do.
    func isAgentRunning(forStory story: ProjectStory, in board: TaskBoard) -> Bool {
        board.tasks(inStory: story.id).contains { isAgentRunning(for: $0) }
    }

    /// Leaves the task board for a fresh chat in `projectId`.
    func startNewChat(inProject projectId: UUID, window: WindowState) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        if window.selectedProject?.id != projectId {
            selectProject(project, in: window)
        }
        startNewChat(in: window)
    }

    // MARK: - Run history

    /// The task's thread transcript: the live in-memory messages when they are
    /// at least as complete as what's on disk, otherwise the persisted history
    /// (the thread may never have been opened this launch). `nil` when the task
    /// has no thread to read.
    func taskRunMessages(for task: ProjectTask) async -> [ChatMessage]? {
        guard let sessionId = task.sessionKey.map(resolveCurrentSessionId),
              let summary = allSessionSummaries.first(where: { $0.id == sessionId }) else { return nil }
        return await taskRunMessages(summary: summary)
    }

    func taskRunMessages(summary: ChatSession.Summary) async -> [ChatMessage] {
        let live = sessionStates[summary.id]?.messages ?? []
        let persisted = await persistedMessages(summary: summary) ?? []
        return live.count >= persisted.count ? live : persisted
    }

    func persistedMessages(sessionId: String) async -> [ChatMessage]? {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionId }) else { return nil }
        return await persistedMessages(summary: summary)
    }

    func persistedMessages(summary: ChatSession.Summary) async -> [ChatMessage]? {
        guard let project = projects.first(where: { $0.id == summary.projectId }) else { return nil }
        return await persistence.loadFullSession(summary: summary, cwd: project.path)?.messages
    }

    /// The task sheet uses the same persisted, session-scoped queue as chat.
    func queuedTaskMessages(for task: ProjectTask) -> [QueuedMessage] {
        guard let sessionId = chatSessionId(for: task) else { return [] }
        return threadStore.loadQueue(sessionKey: sessionId)
    }

    @discardableResult
    func queueTaskFollowUp(_ task: ProjectTask, text: String, attachments: [Attachment]) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              let current = self.task(id: task.id), isAgentRunning(for: current),
              let sessionId = chatSessionId(for: current)
        else { return false }

        let message = QueuedMessage(text: text, attachments: attachments)
        threadStore.appendQueued(sessionKey: sessionId, message: message)
        appendToWindowQueueMirrors(sessionID: sessionId, message: message)
        broadcastMobileSessionStatus(sessionID: sessionId)
        return true
    }

    func removeQueuedTaskMessage(id: UUID, for task: ProjectTask) {
        guard let sessionId = chatSessionId(for: task),
              threadStore.loadQueue(sessionKey: sessionId).contains(where: { $0.id == id })
        else { return }
        threadStore.removeQueued(id: id)
        evictFromWindowQueueMirrors(sessionID: sessionId, queuedID: id)
        broadcastMobileSessionStatus(sessionID: sessionId)
    }

    func canSteerTask(_ task: ProjectTask) -> Bool {
        guard let sessionId = chatSessionId(for: task) else { return false }
        let provider = sessionStates[sessionId]?.agentProvider
            ?? allSessionSummaries.first(where: { $0.id == sessionId })?.agentProvider
            ?? task.agent.provider
            ?? selectedAgentProvider
        return backend(for: provider).supportsSteering
    }

    /// A failed steer leaves the queued entry in place for the normal flush.
    @discardableResult
    func steerQueuedTaskMessage(id: UUID, for task: ProjectTask) async -> Bool {
        guard let sessionId = chatSessionId(for: task),
              let message = threadStore.loadQueue(sessionKey: sessionId).first(where: { $0.id == id }),
              let streamId = sessionStates[sessionId]?.activeStreamId,
              sessionStates[sessionId]?.isStreaming == true
        else { return false }

        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !message.attachments.isEmpty else { return false }
        // Images travel as path lines in the prompt, exactly as on a normal send.
        let resolved = AttachmentFactory.resolvingClipboardImages(message.attachments).resolved
        let provider = sessionStates[sessionId]?.agentProvider
            ?? allSessionSummaries.first(where: { $0.id == sessionId })?.agentProvider
            ?? task.agent.provider
            ?? selectedAgentProvider
        guard await backend(for: provider).steer(
            streamId: streamId,
            prompt: buildPromptWithAttachments(text, attachments: resolved)
        ) else {
            return false
        }

        updateState(sessionId) { state in
            state.messages.append(ChatMessage(role: .user, content: message.text, attachments: resolved))
            state.needsNewMessage = true
            state.unconsumedSteerCount += 1
        }
        await saveSession(sessionId: sessionId, projectId: task.projectId, messages: stateForSession(sessionId).messages)
        removeQueuedTaskMessage(id: id, for: task)
        return true
    }

    /// Sends a follow-up into the task's thread in the background and puts the
    /// task back in the board's first chat column; `TaskBoardHook` moves it on
    /// through that column's session-stop trigger when the turn finishes,
    /// exactly like the first run. Refused while the agent is still running the
    /// task.
    @discardableResult
    func sendTaskFollowUp(_ task: ProjectTask, text: String, attachments: [Attachment] = []) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty,
              let current = self.task(id: task.id), !isStatusLocked(current),
              let sessionId = chatSessionId(for: current)
        else { return false }

        // The send saves the thread from its in-memory messages, so a thread
        // not opened this launch must be hydrated first or its history would
        // be written back as just the follow-up.
        if sessionStates[sessionId]?.messages.isEmpty ?? true,
           let history = await persistedMessages(sessionId: sessionId), !history.isEmpty {
            updateState(sessionId) { $0.messages = history }
        }

        // Written directly rather than through `moveTask`: entering a chat
        // column there dispatches a brand-new run, and this continues the
        // existing one. A board without a chat column leaves the card put.
        let previousStatus = current.status
        if let chatColumn = taskBoard(for: current.projectId).firstChatColumn {
            updateBoard(current.projectId) { board in
                guard let idx = board.tasks.firstIndex(where: { $0.id == current.id }) else { return }
                board.tasks[idx].status = chatColumn.id
                board.tasks[idx].attentionReason = nil
                board.tasks[idx].isQueued = false
                board.tasks[idx].sortIndex = board.appendSortIndex(for: chatColumn.id)
                board.tasks[idx].updatedAt = Date()
            }
        }

        // Pasted images exist only in memory until written out, same as on
        // dispatch.
        let resolved = AttachmentFactory.resolvingClipboardImages(attachments).resolved

        do {
            _ = try await sendCrossProject(
                projectId: current.projectId,
                threadId: sessionId,
                prompt: buildPromptWithAttachments(prompt, attachments: resolved),
                displayText: prompt,
                attachments: resolved,
                waitForResponse: false
            )
            return true
        } catch {
            logger.error("[Tasks] follow-up failed for task \(current.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateBoard(current.projectId) { board in
                guard let idx = board.tasks.firstIndex(where: { $0.id == current.id }),
                      board.tasks[idx].status != previousStatus
                else { return }
                board.tasks[idx].status = previousStatus
                board.tasks[idx].sortIndex = board.appendSortIndex(for: previousStatus)
            }
            return false
        }
    }

    /// Puts the task linked to `sessionKey` back in the board's first chat
    /// column when its thread starts a new turn from outside the task board —
    /// a message typed into the chat itself, or a queued one flushed. Without
    /// this a task the completion check sent back to Pending sits there while
    /// its agent is working again. Written directly rather than through
    /// `moveTask`, which would dispatch a brand-new run.
    func resumeTaskForStreamingSession(_ sessionKey: String) {
        let resolvedKey = resolveCurrentSessionId(sessionKey)
        for (projectId, board) in taskBoards {
            guard let task = board.tasks.first(where: {
                guard let linked = $0.sessionKey else { return false }
                return resolveCurrentSessionId(linked) == resolvedKey
            }) else { continue }
            guard !board.column(for: task.status).triggersChat,
                  let chatColumn = board.firstChatColumn
            else { return }
            updateBoard(projectId) { board in
                guard let idx = board.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                board.tasks[idx].status = chatColumn.id
                board.tasks[idx].attentionReason = nil
                board.tasks[idx].isQueued = false
                board.tasks[idx].sortIndex = board.appendSortIndex(for: chatColumn.id)
                board.tasks[idx].updatedAt = Date()
            }
            logger.info("[Tasks] resumed chat moved task \(task.id.uuidString, privacy: .public) to \(chatColumn.id.rawValue, privacy: .public)")
            return
        }
    }
}
