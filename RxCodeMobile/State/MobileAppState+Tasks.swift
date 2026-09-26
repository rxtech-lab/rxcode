import Foundation
import RxCodeCore
import RxCodeSync

extension MobileAppState {
    // MARK: - Task board round trip

    /// Task mutations can dispatch an agent run on the desktop before it
    /// replies, so they share the autopilot ceiling rather than the snappy
    /// config timeout.
    static let taskBoardTimeout: Duration = .seconds(30)

    /// Sends one task-board operation to the active desktop and awaits its
    /// reply. The returned board is applied before this returns, so callers
    /// only need to handle errors.
    @discardableResult
    func taskBoardCall(_ payload: TaskBoardRequestPayload) async throws -> TaskBoardResultPayload {
        guard isPaired else { throw AutopilotRemoteError.notPaired }
        let desktop = pairedDesktopPubkey
        let result: TaskBoardResultPayload = try await withCheckedThrowingContinuation { continuation in
            pendingTaskBoardRequests[payload.clientRequestID] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.send(.taskBoardRequest(payload), toHex: desktop)
                    self.scheduleTimeout(Self.taskBoardTimeout) { state in
                        if let pending = state.pendingTaskBoardRequests.removeValue(forKey: payload.clientRequestID) {
                            pending.resume(throwing: AutopilotRemoteError.timedOut)
                        }
                    }
                } catch {
                    if let pending = self.pendingTaskBoardRequests.removeValue(forKey: payload.clientRequestID) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok else {
            throw AutopilotRemoteError.server(result.errorMessage ?? String(localized: "The Mac could not complete the request."))
        }
        return result
    }

    func applyTaskBoardResult(_ result: TaskBoardResultPayload) {
        if let snapshot = result.snapshot {
            taskBoardsByProject[snapshot.projectID] = snapshot
        }
        if let continuation = pendingTaskBoardRequests.removeValue(forKey: result.clientRequestID) {
            continuation.resume(returning: result)
        }
    }

    // MARK: - Reads

    /// Whether task-board requests can reach the desktop: paired, connected,
    /// and past the first snapshot (which delivers the project list).
    var isTaskSyncReady: Bool {
        guard isPaired, hasReceivedInitialSnapshot else { return false }
        if case .connected = connectionState { return true }
        return false
    }

    /// Changes whenever task boards should be (re)fetched automatically:
    /// sync becoming ready (launch, reconnect, desktop switch) or the project
    /// list changing. Views key their load `.task` on it, since a Tasks view
    /// can appear — as the first tab does at launch — before sync is ready.
    var taskSyncReloadKey: String {
        "\(isTaskSyncReady)|\(pairedDesktopPubkey)|" + projects.map(\.id.uuidString).joined(separator: ",")
    }

    func taskBoard(for projectID: UUID) -> TaskBoard {
        taskBoardsByProject[projectID]?.board ?? TaskBoard()
    }

    /// The chat thread a task was dispatched into, if it still exists.
    func taskSessionID(_ task: ProjectTask) -> String? {
        taskBoardsByProject[task.projectId]?.sessionID(for: task.id)
    }

    /// True while the task's linked thread is mid-turn.
    func isTaskAgentRunning(_ task: ProjectTask) -> Bool {
        guard let sessionID = taskSessionID(task) else { return false }
        return sessions.first { $0.id == sessionID }?.isStreaming ?? false
    }

    func isTaskClassifying(_ task: ProjectTask) -> Bool {
        taskBoardsByProject[task.projectId]?.classifyingTaskIDs.contains(task.id) ?? false
    }

    /// A blank task parented to `story` (or the board root), prefilled like
    /// the desktop's drafts: first column, the story's version and milestone,
    /// and the desktop's default agent.
    func newTaskDraft(projectID: UUID, story: ProjectStory?) -> ProjectTask {
        let snapshot = taskBoardsByProject[projectID]
        return ProjectTask(
            projectId: projectID,
            storyId: story?.id,
            title: "",
            status: taskBoard(for: projectID).firstColumn.id,
            version: story?.version,
            milestone: story?.milestone,
            agent: snapshot?.defaultAgent ?? TaskAgentConfig()
        )
    }

    // MARK: - Operations

    func loadTaskBoard(projectID: UUID) async throws {
        loadingTaskBoardProjects.insert(projectID)
        defer { loadingTaskBoardProjects.remove(projectID) }
        try await taskBoardCall(TaskBoardRequestPayload(projectID: projectID, operation: .fetch))
    }

    /// Fetches every project's board concurrently. Returns the first error
    /// message, if any board failed to load; the others still apply.
    func loadAllTaskBoards() async -> String? {
        let projectIDs = projects.map(\.id)
        return await withTaskGroup(of: String?.self) { group in
            for projectID in projectIDs {
                group.addTask { @MainActor in
                    do {
                        try await self.loadTaskBoard(projectID: projectID)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            var firstError: String?
            for await error in group where firstError == nil {
                firstError = error
            }
            return firstError
        }
    }

    func saveTask(_ task: ProjectTask) async throws {
        try await taskBoardCall(TaskBoardRequestPayload(projectID: task.projectId, operation: .upsertTask, task: task))
    }

    func deleteTask(_ task: ProjectTask) async throws {
        try await taskBoardCall(TaskBoardRequestPayload(projectID: task.projectId, operation: .deleteTask, taskID: task.id))
    }

    /// Moves a task to `status`, at `sortIndex` when dropped between two
    /// cards (else the end of the column). The move is shown immediately and
    /// rolled back to the desktop's board if the desktop rejects it.
    func moveTask(_ task: ProjectTask, to status: TaskStatus, sortIndex: Double? = nil) async throws {
        if var snapshot = taskBoardsByProject[task.projectId],
           let index = snapshot.board.tasks.firstIndex(where: { $0.id == task.id }) {
            let resolvedIndex = sortIndex ?? snapshot.board.appendSortIndex(for: status)
            snapshot.board.tasks[index].status = status
            snapshot.board.tasks[index].sortIndex = resolvedIndex
            taskBoardsByProject[task.projectId] = snapshot
        }
        do {
            try await taskBoardCall(TaskBoardRequestPayload(
                projectID: task.projectId,
                operation: .moveTask,
                taskID: task.id,
                status: status,
                sortIndex: sortIndex
            ))
        } catch {
            try? await loadTaskBoard(projectID: task.projectId)
            throw error
        }
    }

    /// Moves the task `taskID` so it sits just before `target` in `target`'s
    /// column, or at the end of `status` when there is no target — the drop
    /// half of drag and drop on the board.
    func dropTask(_ taskID: UUID, projectID: UUID, before target: ProjectTask?, in status: TaskStatus) async throws {
        let board = taskBoard(for: projectID)
        guard let task = board.tasks.first(where: { $0.id == taskID }), task.id != target?.id else { return }
        guard !board.isStatusLocked(task) || board.resolvedStatus(of: task) == status else {
            throw AutopilotRemoteError.server(String(localized: "The agent is working on this task; it moves on when the turn finishes."))
        }
        let column = board.tasks(in: status).filter { $0.id != taskID }
        var sortIndex: Double?
        if let target, let position = column.firstIndex(where: { $0.id == target.id }) {
            let after = position > 0 ? column[position - 1] : nil
            sortIndex = TaskBoard.sortIndex(between: after, and: target, in: column)
        }
        try await moveTask(task, to: status, sortIndex: sortIndex)
    }

    /// Runs the task with its assigned agent by moving it into the board's
    /// first chat column — the same path as the desktop's "Run with Agent".
    func runTask(_ task: ProjectTask) async throws {
        guard let column = taskBoard(for: task.projectId).firstChatColumn else { return }
        try await moveTask(task, to: column.id)
    }

    @discardableResult
    func quickAddTask(text: String, projectID: UUID, storyID: UUID?) async throws -> UUID? {
        try await taskBoardCall(TaskBoardRequestPayload(
            projectID: projectID,
            operation: .quickAddTask,
            storyID: storyID,
            text: text
        )).taskID
    }

    func sendTaskFollowUp(_ task: ProjectTask, text: String) async throws {
        try await taskBoardCall(TaskBoardRequestPayload(
            projectID: task.projectId,
            operation: .followUp,
            taskID: task.id,
            text: text
        ))
    }

    /// The task's runs (prompt → final agent answer), read from its thread on
    /// the desktop. `nil` when the task has no thread.
    func fetchTaskRuns(_ task: ProjectTask) async throws -> [TaskRunTurn]? {
        try await taskBoardCall(TaskBoardRequestPayload(
            projectID: task.projectId,
            operation: .fetchRuns,
            taskID: task.id
        )).runs
    }

    func saveStory(_ story: ProjectStory) async throws {
        try await taskBoardCall(TaskBoardRequestPayload(projectID: story.projectId, operation: .upsertStory, story: story))
    }

    func deleteStory(_ story: ProjectStory) async throws {
        try await taskBoardCall(TaskBoardRequestPayload(projectID: story.projectId, operation: .deleteStory, storyID: story.id))
    }

    func saveView(_ view: TaskSavedView, projectID: UUID) async throws {
        try await taskBoardCall(TaskBoardRequestPayload(projectID: projectID, operation: .upsertView, view: view))
    }

}
