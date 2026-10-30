import Foundation
import os
import RxCodeCore
import RxCodeSync

// MARK: - Mobile Sync — Task Board

extension AppState {
    /// The board of `projectId` as mobile renders it, including the resolved
    /// chat thread of every dispatched task.
    func mobileTaskBoardSnapshot(for projectId: UUID) async -> MobileTaskBoardSnapshot {
        var board = taskBoard(for: projectId)
        for index in board.savedViews.indices {
            guard let source = board.savedViews[index].filterScript, board.savedViews[index].hasFilterScript else { continue }
            switch await taskFilterEvaluator.evaluate(script: source, input: TaskFilterScript.input(for: board)) {
            case .selection(let selection):
                board.savedViews[index].filterSnapshot = TaskFilterSnapshot(source: source,
                    tasks: selection.taskIds.map(\.uuidString).sorted(), stories: selection.storyIds.map(\.uuidString).sorted())
            case .failure:
                board.savedViews[index].filterSnapshot = nil
            }
        }
        // Cloud sync bookkeeping is desktop-only and would roughly double the
        // payload; mobile edits come back as per-item operations.
        board.cloudSync = nil
        var sessionIDs: [String: String] = [:]
        for task in board.tasks {
            if let sessionId = chatSessionId(for: task) {
                sessionIDs[task.id.uuidString] = sessionId
            }
        }
        let taskIDs = Set(board.tasks.map(\.id))
        return MobileTaskBoardSnapshot(
            projectID: projectId,
            board: board,
            taskSessionIDs: sessionIDs,
            classifyingTaskIDs: classifyingTaskIds.filter { taskIDs.contains($0) }.sorted { $0.uuidString < $1.uuidString },
            defaultAgent: defaultTaskAgent()
        )
    }

    /// Pushes `projectId`'s board to every paired device shortly after it
    /// changes. Debounced per project so a burst of writes (a drag, an agent
    /// run advancing a card) sends one update.
    func scheduleMobileTaskBoardBroadcast(for projectId: UUID) {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        mobileTaskBoardBroadcastTasks[projectId]?.cancel()
        mobileTaskBoardBroadcastTasks[projectId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.mobileTaskBoardBroadcastTasks[projectId] = nil
            guard self.projects.contains(where: { $0.id == projectId }) else { return }
            MobileSyncService.shared.broadcastTaskBoardUpdate(await self.mobileTaskBoardSnapshot(for: projectId))
        }
    }

    func handleMobileTaskBoardRequest(_ request: TaskBoardRequestPayload, fromHex: String) async {
        logger.info("[MobileSync] handling task board operation=\(request.operation.rawValue, privacy: .public) project=\(request.projectID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        if let cloudProjectID = request.cloudProjectID {
            await runMobileCloudTask(request, cloudProjectID: cloudProjectID, fromHex: fromHex)
            return
        }
        guard projects.contains(where: { $0.id == request.projectID }) else {
            await replyTaskBoardResult(request, ok: false, errorMessage: String(localized: "Project not found on desktop."), toHex: fromHex)
            return
        }
        await ensureTaskBoardLoaded(for: request.projectID)

        if request.operation == .fetchRuns {
            guard let task = requestedTask(request) else {
                await replyTaskBoardResult(request, ok: false, errorMessage: MobileTaskBoardError.taskNotFound.localizedDescription, toHex: fromHex)
                return
            }
            let runs = await taskRunMessages(for: task).map(TaskRunTurn.turns(from:))
            await replyTaskBoardResult(request, ok: true, taskID: task.id, runs: runs, toHex: fromHex)
            return
        }

        do {
            let touchedTaskID = try await applyMobileTaskBoardOperation(request)
            await replyTaskBoardResult(request, ok: true, taskID: touchedTaskID, toHex: fromHex)
        } catch {
            logger.error("[MobileSync] task board operation=\(request.operation.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            await replyTaskBoardResult(request, ok: false, errorMessage: error.localizedDescription, toHex: fromHex)
        }
    }

    /// Applies one mobile operation through the same `AppState` entry points
    /// the desktop board uses, so column triggers and agent dispatch behave
    /// identically. Returns the task the operation created or touched.
    private func applyMobileTaskBoardOperation(_ request: TaskBoardRequestPayload) async throws -> UUID? {
        let projectId = request.projectID
        let board = taskBoard(for: projectId)
        if request.operation != .fetch && request.operation != .fetchRuns {
            if let task = board.tasks.first(where: { $0.id == (request.taskID ?? request.task?.id) }), !canEditCard(task) {
                throw MobileTaskBoardError.missing("permission to edit this card")
            }
            if let story = board.stories.first(where: { $0.id == (request.storyID ?? request.story?.id) }), !canEditCard(story) {
                throw MobileTaskBoardError.missing("permission to edit this card")
            }
        }
        switch request.operation {
        case .fetch, .fetchRuns:
            return nil

        case .upsertTask:
            guard var task = request.task else { throw MobileTaskBoardError.missing("task") }
            task.projectId = projectId
            let board = taskBoard(for: projectId)
            if let stored = board.tasks.first(where: { $0.id == task.id }) {
                // Run links are desktop-owned; a stale phone copy must not
                // unlink a thread or unlock an agent-owned card.
                task.sessionKey = stored.sessionKey
                task.sourceSessionKey = stored.sourceSessionKey
                task.createdAt = stored.createdAt
                if isStatusLocked(stored) {
                    task.status = stored.status
                }
                task.sortIndex = task.status == stored.status
                    ? stored.sortIndex
                    : board.appendSortIndex(for: task.status)
            }
            upsertTask(task)
            return task.id

        case .deleteTask:
            guard let task = requestedTask(request) else { throw MobileTaskBoardError.taskNotFound }
            deleteTask(task)
            return task.id

        case .moveTask:
            guard var task = requestedTask(request) else { throw MobileTaskBoardError.taskNotFound }
            guard let status = request.status else { throw MobileTaskBoardError.missing("status") }
            if isStatusLocked(task), taskBoard(for: projectId).resolvedStatus(of: task) != status {
                throw MobileTaskBoardError.statusLocked
            }
            if let agent = request.runAgent, !isStatusLocked(task) {
                task.agent = agent
                upsertTask(task)
            }
            moveTask(task, to: status, sortIndex: request.sortIndex)
            return task.id

        case .quickAddTask:
            let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw MobileTaskBoardError.missing("text") }
            let task = quickAddTask(text: text, projectId: projectId, storyId: request.storyID)
            return task.id

        case .followUp:
            guard let task = requestedTask(request) else { throw MobileTaskBoardError.taskNotFound }
            let text = request.text ?? ""
            guard await sendTaskFollowUp(task, text: text) else { throw MobileTaskBoardError.followUpFailed }
            return task.id

        case .upsertStory:
            guard var story = request.story else { throw MobileTaskBoardError.missing("story") }
            story.projectId = projectId
            if let stored = taskBoard(for: projectId).story(id: story.id) {
                story.createdAt = stored.createdAt
            }
            upsertStory(story)
            return nil

        case .deleteStory:
            guard let storyID = request.storyID,
                  let story = taskBoard(for: projectId).story(id: storyID)
            else { throw MobileTaskBoardError.storyNotFound }
            deleteStory(story)
            return nil

        case .editMetadata:
            guard let edit = request.metadataEdit, !edit.name.isEmpty else { throw MobileTaskBoardError.missing("metadataEdit") }
            updateBoard(projectId) { edit.apply(to: &$0) }
            return nil

        case .upsertView:
            guard var view = request.view else { throw MobileTaskBoardError.missing("view") }
            // The phone can edit standard settings, but cannot replace or
            // remove Swift code, including through a stale editor draft.
            view.filterScript = taskBoard(for: projectId).effectiveViews
                .first(where: { $0.id == view.id })?.filterScript
            upsertSavedView(view, projectId: projectId)
            return nil

        }
    }

    /// Runs a phone's cloud-board task on this Mac. The phone picked this Mac
    /// to run it, so the task is assigned here (and to the default agent when
    /// it has none) before it enters a chat column the usual way.
    private func runMobileCloudTask(_ request: TaskBoardRequestPayload, cloudProjectID: String, fromHex: String) async {
        func fail(_ message: String) async {
            await MobileSyncService.shared.send(.taskBoardResult(TaskBoardResultPayload(
                clientRequestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: message
            )), toHex: fromHex)
        }
        guard request.operation == .moveTask else {
            await fail(String(localized: "This Mac can only run cloud tasks."))
            return
        }
        guard let project = projects.first(where: { $0.cloudId == cloudProjectID }) else {
            await fail(String(localized: "This project isn't open on this Mac. Open it from Flowcy on the Mac, then try again."))
            return
        }
        await ensureTaskBoardLoaded(for: project.id)
        func localTask() -> ProjectTask? {
            let board = taskBoard(for: project.id)
            guard let id = board.cloudSync?.localTaskId(forRemote: request.cloudTaskID) else { return nil }
            return board.tasks.first { $0.id == id }
        }
        if localTask() == nil {
            // The task may be newer than this Mac's last pull.
            await syncCloudBoard(projectId: project.id)
        }
        guard var task = localTask() else {
            await fail(MobileTaskBoardError.taskNotFound.localizedDescription)
            return
        }

        if !isStatusLocked(task) {
            task.assignedDeviceId = cloudDeviceID
            if let agent = request.runAgent {
                task.agent = agent
            } else if !task.agent.isAssigned {
                task.agent = defaultTaskAgent()
            }
            upsertTask(task)
            let board = taskBoard(for: project.id)
            if let stored = self.task(id: task.id) {
                if board.column(for: stored.status).triggersChat {
                    // Already in a chat column from a cloud pull, so a move
                    // would not dispatch it.
                    Task { await startTask(stored) }
                } else if let target = request.status.flatMap({ status in
                    board.effectiveColumns.first { $0.id == status && $0.triggersChat }
                }) ?? board.firstChatColumn {
                    moveTask(stored, to: target.id)
                }
            }
        }

        await MobileSyncService.shared.send(.taskBoardResult(TaskBoardResultPayload(
            clientRequestID: request.clientRequestID,
            projectID: project.id,
            ok: true,
            snapshot: await mobileTaskBoardSnapshot(for: project.id),
            taskID: task.id
        )), toHex: fromHex)
    }

    private func requestedTask(_ request: TaskBoardRequestPayload) -> ProjectTask? {
        guard let id = request.taskID ?? request.task?.id else { return nil }
        return taskBoard(for: request.projectID).tasks.first { $0.id == id }
    }

    private func replyTaskBoardResult(
        _ request: TaskBoardRequestPayload,
        ok: Bool,
        errorMessage: String? = nil,
        taskID: UUID? = nil,
        runs: [TaskRunTurn]? = nil,
        toHex hex: String
    ) async {
        let exists = projects.contains { $0.id == request.projectID }
        let result = TaskBoardResultPayload(
            clientRequestID: request.clientRequestID,
            projectID: request.projectID,
            ok: ok,
            errorMessage: errorMessage,
            snapshot: exists ? await mobileTaskBoardSnapshot(for: request.projectID) : nil,
            taskID: taskID,
            runs: runs
        )
        await MobileSyncService.shared.send(.taskBoardResult(result), toHex: hex)
    }
}

private enum MobileTaskBoardError: LocalizedError {
    case missing(String)
    case taskNotFound
    case storyNotFound
    case statusLocked
    case followUpFailed

    var errorDescription: String? {
        switch self {
        case .missing(let field):
            return String(localized: "The request is missing \(field).")
        case .taskNotFound:
            return String(localized: "Task not found on desktop.")
        case .storyNotFound:
            return String(localized: "Story not found on desktop.")
        case .statusLocked:
            return String(localized: "The agent is working on this task; it moves on when the turn finishes.")
        case .followUpFailed:
            return String(localized: "The follow-up could not be sent to the task's chat.")
        }
    }
}
