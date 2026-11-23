import Foundation
import os
import RxCodeCore

extension AppState {
    /// The thread row and its checkpoint move together when a provider assigns its native ID.
    func beginTurnRecovery(sessionID: String, streamID: UUID) async {
        guard let index = allSessionSummaries.firstIndex(where: { $0.id == sessionID }) else { return }
        if allSessionSummaries[index].hasUnfinishedTurn == true,
           allSessionSummaries[index].origin == .cliBacked {
            // A recovered Claude turn can contain output the CLI never committed to JSONL.
            allSessionSummaries[index].origin = .legacyRxCode
            threadStore.upsert(allSessionSummaries[index])
        }
        sessionStates[sessionID]?.latestTurnID = streamID
        setTurnUnfinished(true, sessionID: sessionID)
        await checkpointTurn(sessionID: sessionID, streamID: streamID)
    }

    /// Coalesce events independently of the visible window's text flush timer.
    func scheduleTurnCheckpoint(sessionID: String, streamID: UUID) {
        guard let state = sessionStates[sessionID], state.activeStreamId == streamID,
              state.checkpointTask == nil else { return }
        sessionStates[sessionID]?.checkpointTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            let key = resolveCurrentSessionId(sessionID)
            guard sessionStates[key]?.activeStreamId == streamID else { return }
            sessionStates[key]?.checkpointTask = nil
            await checkpointTurn(sessionID: key, streamID: streamID)
        }
    }

    func checkpointTurn(sessionID: String, streamID: UUID) async {
        guard sessionStates[sessionID]?.activeStreamId == streamID else { return }
        flushPendingUpdates(for: sessionID, forceText: true)
        sessionStates[sessionID]?.checkpointRevision += 1
        guard let snapshot = sessionStates[sessionID] else { return }
        do {
            let data = try await Self.encodeCheckpoint(snapshot.messages)
            let key = resolveCurrentSessionId(sessionID)
            guard let current = sessionStates[key], current.activeStreamId == streamID,
                  current.checkpointRevision == snapshot.checkpointRevision else { return }
            threadStore.saveUnfinishedTranscript(data, sessionID: key)
        } catch {
            logger.error("Failed to checkpoint thread \(sessionID): \(error.localizedDescription)")
        }
    }

    @concurrent
    private static func encodeCheckpoint(_ messages: [ChatMessage]) async throws -> Data {
        try JSONEncoder().encode(messages)
    }

    func checkpointActiveTurns() async {
        for (key, state) in sessionStates where state.isStreaming {
            if let id = state.activeStreamId {
                await checkpointTurn(sessionID: resolveCurrentSessionId(key), streamID: id)
            }
        }
    }

    func interruptStream(sessionID: String, streamID: UUID, projectID: UUID, message: String) async {
        guard sessionStates[sessionID]?.activeStreamId == streamID else { return }
        flushPendingUpdates(for: sessionID, forceText: true)
        updateState(sessionID) { $0.messages.append(ChatMessage(role: .assistant, content: message, isError: true)) }
        await checkpointTurn(sessionID: sessionID, streamID: streamID)
        guard sessionStates[sessionID]?.activeStreamId == streamID else { return }
        finalizeStreamSession(for: sessionID, interrupted: true)
        recordStreamCompletion(streamId: streamID, sessionId: sessionID,
                               assistantText: lastAssistantResponseText(in: stateForSession(sessionID).messages), error: message)
        await awaitPendingShellDetections(for: sessionID)
        await saveSession(sessionId: sessionID, projectId: projectID, messages: stateForSession(sessionID).messages)
    }

    func setTurnUnfinished(_ unfinished: Bool, sessionID: String) {
        guard let index = allSessionSummaries.firstIndex(where: { $0.id == sessionID }) else { return }
        allSessionSummaries[index].hasUnfinishedTurn = unfinished
        threadStore.setTurnOutcome(sessionID: sessionID, unfinished: unfinished)
    }

    /// Publish the outcome immediately. The final transcript save commits it to disk.
    func settleTurn(sessionID: String, interrupted: Bool, preservePartialTranscript: Bool = false) {
        sessionStates[sessionID]?.checkpointTask?.cancel()
        sessionStates[sessionID]?.checkpointTask = nil
        guard let index = allSessionSummaries.firstIndex(where: { $0.id == sessionID }) else { return }
        allSessionSummaries[index].hasUnfinishedTurn = interrupted
        if (interrupted || preservePartialTranscript), allSessionSummaries[index].origin == .cliBacked {
            allSessionSummaries[index].origin = .legacyRxCode
        }
    }

    func restoreLegacyTurnOutcome(_ messages: [ChatMessage], sessionID: String) {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
              summary.hasUnfinishedTurn == nil, sessionActivity[sessionID]?.isStreaming != true,
              let last = messages.last else { return }
        setTurnUnfinished(last.isError || last.isStreaming || last.role == .user, sessionID: sessionID)
    }

    func loadLegacyTurnOutcome(for summary: ChatSession.Summary) async {
        guard summary.hasUnfinishedTurn == nil, let project = sessionProject(id: summary.projectId),
              let full = await persistence.loadFullSession(summary: summary, cwd: summary.worktreePath ?? project.path),
              !Task.isCancelled else { return }
        restoreLegacyTurnOutcome(full.messages, sessionID: summary.id)
    }

    @discardableResult
    func resumeInterruptedTurn(in window: WindowState) async -> UUID? {
        guard let key = window.currentSessionId,
              let summary = allSessionSummaries.first(where: { $0.id == key }), summary.hasUnfinishedTurn == true,
              let state = sessionStates[key], !state.isStreaming, !state.isLoadingFromDisk,
              let lastUserIndex = state.messages.lastIndex(where: { $0.role == .user }) else { return nil }

        var prompt = "Continue the interrupted task from where you stopped."
        let provider = state.agentProvider ?? summary.agentProvider
        if provider != .flowcy && (resumeSessionId(for: provider, threadId: key) == nil || provider == .acp || provider == .localAgent) {
            // A turn can fail before receiving a native ID. ACP clients can also
            // open a fresh native session when their original process has exited.
            let context = state.messages[lastUserIndex...]
                .filter { !$0.isError }
                .map { message in
                    let blocks = message.blocks.compactMap { block in
                        block.text ?? block.toolCall.map { "\($0.name): \($0.result ?? "unfinished")" }
                    }
                    return ([message.role.rawValue] + blocks + message.attachmentPaths.map(\.path)).joined(separator: "\n")
                }.joined(separator: "\n\n")
            prompt += "\n\nInterrupted turn:\n\(context)"
        }
        return await sendPrompt(prompt, skipAppendingUserMessage: true, in: window)
    }
}
