import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync

// MARK: - Non-Blocking Shell & Structured File Change Tracking

extension AppState {

    /// Returns the root PID of a subprocess dedicated to this stream.
    func streamRootPid(provider: AgentProvider, streamId: UUID) async -> Int32? {
        guard agentBackendOverrides[provider] == nil else { return nil }
        switch provider {
        case .claudeCode:
            return await claude.rootPid(for: streamId)
        case .codex:
            return await codex.rootPid(for: streamId)
        case .acp:
            return await acp.rootPid(for: streamId)
        case .localAgent, .flowcy:
            return nil
        }
    }

    /// Registers a newly started stream with the workspace's `WorkspaceChangeTracker`.
    ///
    /// Registration is fire-and-forget: `streamDidStart` can seed its baseline
    /// ledger with git, and the caller (`processStream`) must not wait on that
    /// before consuming agent events. Otherwise a slow or wedged git call leaves
    /// the thread spinning forever with no messages, no pending→real session
    /// promotion, and no inactivity watchdog. Shell spans opened before the
    /// registration lands already fall back to the workspace root / span PID.
    func shellTrackerBeginStream(
        streamId: UUID,
        sessionKey: String,
        cwd: String,
        agentProvider: AgentProvider
    ) {
        sessionStates[sessionKey, default: SessionStreamState()].activeStreamCwd = cwd
        #if os(macOS)
        guard !cwd.isEmpty else { return }
        shellTrackerBeginTasks[streamId] = Task { [weak self] in
            guard let tracker = await WorkspaceChangeTrackerRegistry.shared.tracker(for: cwd) else { return }
            let initialPid = await self?.streamRootPid(provider: agentProvider, streamId: streamId)
            // The session may have been promoted (pending → real) while this
            // registration was queued; register under the live key so a rename
            // that already ran on the tracker isn't undone.
            let liveKey = self?.resolveCurrentSessionId(sessionKey) ?? sessionKey
            await tracker.streamDidStart(
                streamId: streamId,
                sessionKey: liveKey,
                cwd: cwd,
                rootPid: initialPid
            )
            if initialPid == nil, agentProvider != .localAgent, agentProvider != .flowcy {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self,
                      let spawnedPid = await self.streamRootPid(provider: agentProvider, streamId: streamId)
                else { return }
                await tracker.updateStreamRootPid(streamId: streamId, rootPid: spawnedPid)
            }
        }
        #endif
    }

    /// Keeps active shell spans and in-flight detection tasks aligned when a
    /// `pending-…` or `compact_boundary` session key is promoted to a new id.
    func shellTrackerRenameSession(from oldKey: String, to newKey: String, cwd: String) {
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else { return }
        if let tasks = pendingShellDetectionTasks.removeValue(forKey: oldKey), !tasks.isEmpty {
            var merged = pendingShellDetectionTasks[newKey] ?? [:]
            for (id, task) in tasks { merged[id] = task }
            pendingShellDetectionTasks[newKey] = merged
        }
        #if os(macOS)
        guard !cwd.isEmpty else { return }
        Task {
            guard let tracker = await WorkspaceChangeTrackerRegistry.shared.tracker(for: cwd) else { return }
            await tracker.renameSession(from: oldKey, to: newKey)
        }
        #endif
    }

    /// Cleans up per-stream tracker state after all pending tool-result detections drain.
    func shellTrackerEndStream(streamId: UUID, sessionKey: String, cwd: String) {
        #if os(macOS)
        guard !cwd.isEmpty else { return }
        let beginTask = shellTrackerBeginTasks.removeValue(forKey: streamId)
        Task { @MainActor [weak self] in
            await beginTask?.value
            await self?.awaitPendingShellDetections(for: sessionKey)
            guard let tracker = await WorkspaceChangeTrackerRegistry.shared.tracker(for: cwd) else { return }
            await tracker.streamDidEnd(streamId: streamId)
        }
        #endif
    }

    /// Opens or updates an active shell execution span without delaying execution.
    func shellTrackerUpsertToolSpan(
        id: String,
        name: String,
        input: [String: JSONValue],
        sessionKey: String
    ) {
        #if os(macOS)
        let probe = ToolCall(id: id, name: name, input: input)
        guard probe.isShellExecutionTool else { return }
        let resolvedKey = resolveCurrentSessionId(sessionKey)
        guard let state = sessionStates[resolvedKey],
              let streamId = state.activeStreamId,
              let rootCwd = state.activeStreamCwd,
              !rootCwd.isEmpty else { return }
        let command = probe.shellCommandString
        let effectiveCwd = probe.shellWorkingDirectory ?? rootCwd
        let scriptPath = probe.referencedScriptPath
        let provider = state.agentProvider ?? selectedAgentProvider

        Task { [weak self] in
            guard let tracker = await WorkspaceChangeTrackerRegistry.shared.tracker(for: rootCwd) else { return }
            let pid = await self?.streamRootPid(provider: provider, streamId: streamId)
            await tracker.upsertShellSpan(
                streamId: streamId,
                sessionKey: resolvedKey,
                toolUseId: id,
                command: command,
                cwd: effectiveCwd,
                rootPid: pid,
                extraScriptPath: scriptPath
            )
        }
        #endif
    }

    /// Persists structured `Edit`/`MultiEdit`/`Write` file edits with external-interleaving
    /// detection and synchronizes the workspace rolling ledger so subsequent shell commands
    /// in the same turn only see deltas beyond the structured edit.
    func persistStructuredFileEdits(
        _ infos: [(path: String, hunks: [PreviewFile.EditHunk], isWrite: Bool)],
        state: SessionStreamState,
        sessionKey: String
    ) {
        guard !infos.isEmpty else { return }
        let cwdLocal = state.activeStreamCwd
        for info in infos {
            let snapshot = state.editingFileSnapshots[info.path] ?? nil
            let stepSnapshot = state.latestStepSnapshots[info.path] ?? nil
            let pathLocal = info.path
            let hunksLocal = info.hunks
            let isWriteLocal = info.isWrite
            let initialKey = sessionKey
            let taskId = UUID()

            let task = Task { @MainActor [weak self] in
                defer { self?.removePendingShellDetectionTask(id: taskId, initialSessionKey: initialKey) }
                let modified = await Task.detached(priority: .userInitiated) {
                    try? String(contentsOfFile: pathLocal, encoding: .utf8)
                }.value
                guard let self else { return }
                #if os(macOS)
                if let cwdLocal, !cwdLocal.isEmpty,
                   let tracker = await WorkspaceChangeTrackerRegistry.shared.tracker(for: cwdLocal) {
                    await tracker.recordStructuredEdit(path: pathLocal, modifiedContent: modified)
                }
                #endif
                let resolvedKey = self.resolveCurrentSessionId(initialKey)
                guard self.threadStore.appendFileEdit(
                    sessionId: resolvedKey,
                    path: pathLocal,
                    hunks: hunksLocal,
                    containsWrite: isWriteLocal,
                    originalContent: snapshot,
                    modifiedContent: modified,
                    stepBeforeContent: stepSnapshot
                ) else { return }
                self.recordThreadFileEdits(sessionId: resolvedKey, paths: [pathLocal])
                self.broadcastMobileFileEditsChanged(sessionID: resolvedKey)
            }
            registerPendingShellDetectionTask(task, id: taskId, sessionKey: sessionKey)
        }
    }

    /// Completes a shell tool execution span when its `tool_result` arrives, attributes
    /// workspace file changes per thread, attaches compact file-change diffs directly to
    /// the `ToolCall` in chat ("show on each detect"), and records `ThreadFileEdit` rows.
    func handleCompletedShellToolCallIfNeeded(
        call: ToolCall?,
        sessionKey: String,
        state: SessionStreamState
    ) {
        #if os(macOS)
        guard let call,
              call.isShellExecutionTool,
              let streamId = state.activeStreamId,
              let rootCwd = state.activeStreamCwd,
              !rootCwd.isEmpty else { return }

        let toolUseId = call.id
        let fallbackCommand = call.shellCommandString
        let effectiveCwd = call.shellWorkingDirectory ?? rootCwd
        let scriptPath = call.referencedScriptPath
        let provider = state.agentProvider ?? selectedAgentProvider
        let initialKey = sessionKey
        let taskId = UUID()

        let task = Task { @MainActor [weak self] in
            defer { self?.removePendingShellDetectionTask(id: taskId, initialSessionKey: initialKey) }
            guard let self,
                  let tracker = await WorkspaceChangeTrackerRegistry.shared.tracker(for: rootCwd) else { return }
            let pid = await self.streamRootPid(provider: provider, streamId: streamId)
            let currentKey = self.resolveCurrentSessionId(initialKey)
            let detected = await tracker.endShellSpan(
                streamId: streamId,
                sessionKey: currentKey,
                toolUseId: toolUseId,
                fallbackCommand: fallbackCommand,
                cwd: effectiveCwd,
                rootPid: pid,
                extraScriptPath: scriptPath
            )

            let visibleEdits = detected.filter { !PlanLogic.isPlanFilePath($0.path) }
            guard !visibleEdits.isEmpty else { return }

            let resolvedKey = self.resolveCurrentSessionId(initialKey)
            var persistedPaths: [String] = []
            for edit in visibleEdits {
                let persisted = self.threadStore.appendFileEdit(
                    sessionId: resolvedKey,
                    path: edit.path,
                    hunks: edit.hunks,
                    containsWrite: edit.kind == .created,
                    originalContent: edit.beforeContent,
                    modifiedContent: edit.afterContent ?? (edit.kind == .deleted ? "" : nil),
                    stepBeforeContent: edit.beforeContent,
                    isDeleted: edit.kind == .deleted,
                    isAmbiguous: edit.chatChange.isAmbiguous
                )
                if persisted {
                    persistedPaths.append(edit.path)
                }
            }

            let chatChanges = visibleEdits.map(\.chatChange)
            self.threadStore.upsertDetectedToolChanges(
                sessionId: resolvedKey,
                toolCallId: toolUseId,
                changes: chatChanges
            )

            self.updateState(resolvedKey) { sessionState in
                for edit in visibleEdits {
                    if sessionState.editingFileSnapshots[edit.path] == nil {
                        sessionState.editingFileSnapshots[edit.path] = edit.beforeContent
                    }
                    sessionState.latestStepSnapshots[edit.path] = edit.afterContent
                }
                for msgIdx in sessionState.messages.indices.reversed() {
                    guard let blockIdx = sessionState.messages[msgIdx].toolCallIndex(id: toolUseId) else {
                        continue
                    }
                    sessionState.messages[msgIdx].blocks[blockIdx].toolCall?.setDetectedShellFileChanges(chatChanges)
                    break
                }
            }
            self.recordThreadFileEdits(sessionId: resolvedKey, paths: persistedPaths)
            self.broadcastMobileFileEditsChanged(sessionID: resolvedKey)
        }
        registerPendingShellDetectionTask(task, id: taskId, sessionKey: sessionKey)
        #endif
    }

    /// Drains any in-flight shell/structured edit detection tasks for `sessionKey`
    /// so `CodeReviewHook` and `saveSession` observe every detected file edit.
    func awaitPendingShellDetections(for sessionKey: String) async {
        while true {
            let resolvedKey = resolveCurrentSessionId(sessionKey)
            let batch = Array((pendingShellDetectionTasks[resolvedKey] ?? [:]).values)
            guard !batch.isEmpty else { break }
            for task in batch {
                _ = await task.value
            }
        }
    }

    /// Rehydrates persisted `DetectedShellFileChange` metadata onto `ToolCall`s
    /// when loading sessions from disk.
    func rehydrateDetectedToolChanges(
        in messages: [ChatMessage],
        sessionId: String
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        let byToolId = threadStore.loadDetectedToolChanges(sessionId: sessionId)
        guard !byToolId.isEmpty else { return messages }

        return messages.map { message in
            guard message.role == .assistant else { return message }
            var mutated = false
            let updatedBlocks: [MessageBlock] = message.blocks.map { block in
                guard var call = block.toolCall,
                      let changes = byToolId[call.id],
                      !changes.isEmpty else {
                    return block
                }
                mutated = true
                call.setDetectedShellFileChanges(changes)
                return .toolCall(call)
            }
            guard mutated else { return message }
            var copy = message
            copy.blocks = updatedBlocks
            return copy
        }
    }

    // MARK: - Task Tracking Helpers

    private func registerPendingShellDetectionTask(
        _ task: Task<Void, Never>,
        id: UUID,
        sessionKey: String
    ) {
        let resolvedKey = resolveCurrentSessionId(sessionKey)
        pendingShellDetectionTasks[resolvedKey, default: [:]][id] = task
    }

    private func removePendingShellDetectionTask(id: UUID, initialSessionKey: String) {
        let resolvedKey = resolveCurrentSessionId(initialSessionKey)
        pendingShellDetectionTasks[resolvedKey]?.removeValue(forKey: id)
        if pendingShellDetectionTasks[resolvedKey]?.isEmpty == true {
            pendingShellDetectionTasks.removeValue(forKey: resolvedKey)
        }
        if resolvedKey != initialSessionKey {
            pendingShellDetectionTasks[initialSessionKey]?.removeValue(forKey: id)
            if pendingShellDetectionTasks[initialSessionKey]?.isEmpty == true {
                pendingShellDetectionTasks.removeValue(forKey: initialSessionKey)
            }
        }
    }
}
