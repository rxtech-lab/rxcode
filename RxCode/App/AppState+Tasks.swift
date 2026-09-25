import Foundation
import os
import RxCodeCore

/// Project task-board operations: CRUD over `TaskBoard`, column moves, and
/// dispatching a task to its assigned agent.
///
/// Boards are persisted one JSON file per project (`task_board/<id>.json`) via
/// `PersistenceService`, mirroring run profiles and hook profiles. The board the
/// UI renders is an aggregation across every project.
extension AppState {

    // MARK: - Loading

    func taskBoard(for projectId: UUID) -> TaskBoard {
        taskBoards[projectId] ?? TaskBoard()
    }

    /// Reads one project's board from disk if we haven't already. No-op if
    /// already loaded — a present entry (even an empty board) means loaded,
    /// mirroring `ensureRunProfilesLoaded`.
    func ensureTaskBoardLoaded(for projectId: UUID) async {
        if taskBoards[projectId] != nil { return }
        taskBoards[projectId] = await persistence.loadTaskBoard(projectId: projectId)
    }

    /// Reads every known project's board. Called once from app lifecycle; the
    /// decode happens inside the persistence actor so the main actor isn't
    /// blocked on file I/O.
    func loadAllTaskBoards() async {
        for project in projects {
            await ensureTaskBoardLoaded(for: project.id)
        }
        releaseInterruptedTasks()
    }

    /// Moves agent-owned In Progress tasks to Pending Review. Run once at
    /// launch: nothing is streaming yet, so any such task belongs to a run the
    /// last app session was cut off from, and its session-end hook will never
    /// fire. Without this the task would stay locked in In Progress.
    func releaseInterruptedTasks() {
        for (projectId, board) in taskBoards where board.tasks.contains(where: \.isStatusLocked) {
            updateBoard(projectId) { board in
                for idx in board.tasks.indices where board.tasks[idx].isStatusLocked {
                    board.tasks[idx].status = .pendingReview
                    board.tasks[idx].sortIndex = board.appendSortIndex(for: .pendingReview)
                    board.tasks[idx].updatedAt = Date()
                }
            }
        }
    }

    // MARK: - Persisting

    /// Replaces a project's board in memory and writes it back atomically.
    func setTaskBoard(_ board: TaskBoard, for projectId: UUID) {
        taskBoards[projectId] = board
        Task { [persistence] in
            do {
                try await persistence.saveTaskBoard(board, projectId: projectId)
            } catch {
                logger.error("Failed to save task board: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Mutates a project's board in place and persists the result.
    private func updateBoard(_ projectId: UUID, _ mutate: (inout TaskBoard) -> Void) {
        var board = taskBoard(for: projectId)
        mutate(&board)
        setTaskBoard(board, for: projectId)
    }

    /// Drops a deleted project's board from memory and disk.
    func deleteTaskBoard(for projectId: UUID) {
        taskBoards.removeValue(forKey: projectId)
        Task { [persistence] in
            do {
                try await persistence.deleteTaskBoard(projectId: projectId)
            } catch {
                logger.error("Failed to delete task board: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Aggregated reads

    /// Every task across every project, newest column order preserved.
    /// `projectFilter` of `nil` means "all projects".
    func allTasks(projectFilter: UUID? = nil, savedView: TaskSavedView? = nil) -> [ProjectTask] {
        let boards: [(UUID, TaskBoard)] = taskBoards
            .filter { projectFilter == nil || $0.key == projectFilter }
            .map { ($0.key, $0.value) }
        var result = boards.flatMap(\.1.tasks)
        if let savedView, !savedView.isEmpty {
            result = result.filter(savedView.matches)
        }
        return result.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Tasks in one column, for the current filter.
    func tasks(in status: TaskStatus, projectFilter: UUID? = nil, savedView: TaskSavedView? = nil) -> [ProjectTask] {
        allTasks(projectFilter: projectFilter, savedView: savedView).filter { $0.status == status }
    }

    func story(for task: ProjectTask) -> ProjectStory? {
        taskBoard(for: task.projectId).story(id: task.storyId)
    }

    func task(id: UUID) -> ProjectTask? {
        for board in taskBoards.values {
            if let found = board.tasks.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Distinct tags across the filtered scope, for the saved-view editor.
    func allTaskTags(projectFilter: UUID? = nil) -> [String] {
        Array(Set(allTasks(projectFilter: projectFilter).flatMap(\.tags))).sorted()
    }

    /// Distinct versions across the filtered scope.
    func allTaskVersions(projectFilter: UUID? = nil) -> [String] {
        Array(Set(allTasks(projectFilter: projectFilter).compactMap(\.version)).filter { !$0.isEmpty })
            .sorted(by: >)
    }

    func stories(projectFilter: UUID? = nil) -> [ProjectStory] {
        taskBoards
            .filter { projectFilter == nil || $0.key == projectFilter }
            .flatMap(\.value.stories)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func savedViews(projectFilter: UUID? = nil) -> [TaskSavedView] {
        taskBoards
            .filter { projectFilter == nil || $0.key == projectFilter }
            .flatMap(\.value.savedViews)
            .sorted { $0.name < $1.name }
    }

    /// The tabs a project's task page shows. Falls back to the implicit
    /// default board so a project never has zero views.
    func taskViews(for projectId: UUID) -> [TaskSavedView] {
        taskBoard(for: projectId).effectiveViews
    }

    /// One project's stories, most recently active first — what the
    /// all-projects overview shows. A story's activity includes its tasks, so
    /// adding or moving a child task bubbles the story up. With a keyword, a
    /// story matches on its own text or on any child task's.
    func recentStories(for projectId: UUID, keyword: String = "") -> [ProjectStory] {
        let board = taskBoard(for: projectId)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = board.stories.filter { story in
            trimmed.isEmpty
                || story.matches(keyword: trimmed)
                || board.tasks(inStory: story.id).contains { $0.matches(keyword: trimmed) }
        }
        return matching
            .map { story in
                let lastActivity = board.tasks(inStory: story.id).map(\.updatedAt).max() ?? .distantPast
                return (story, max(story.updatedAt, lastActivity))
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - Default agent

    private static let lastTaskProviderKey = "taskLastAgentProvider"
    private static let lastTaskModelKey = "taskLastAgentModel"

    /// The agent a new task starts with: the model last picked in a task form,
    /// falling back to the app's current model selection.
    func defaultTaskAgent() -> TaskAgentConfig {
        if let provider = workspaceDefaults.string(for: Self.lastTaskProviderKey).flatMap(AgentProvider.init(rawValue:)),
           let model = workspaceDefaults.string(for: Self.lastTaskModelKey), !model.isEmpty {
            return TaskAgentConfig(provider: provider, model: model)
        }
        return TaskAgentConfig(provider: selectedAgentProvider, model: selectedModel)
    }

    /// Records a model picked in a task form as the default for new tasks.
    func rememberTaskAgentModel(provider: AgentProvider, model: String) {
        workspaceDefaults.set(provider.rawValue, for: Self.lastTaskProviderKey)
        workspaceDefaults.set(model, for: Self.lastTaskModelKey)
    }

    // MARK: - Task CRUD

    /// Inserts or replaces a task. New tasks land at the end of their column.
    func upsertTask(_ task: ProjectTask) {
        var stamped = task
        stamped.updatedAt = Date()
        updateBoard(task.projectId) { board in
            if let idx = board.tasks.firstIndex(where: { $0.id == stamped.id }) {
                // Enforced here as well as in the form, so no edit path can
                // rewrite what an already-started task was asked to do.
                if board.tasks[idx].isDescriptionLocked {
                    stamped.details = board.tasks[idx].details
                }
                board.tasks[idx] = stamped
            } else {
                if stamped.sortIndex == 0 {
                    stamped.sortIndex = board.appendSortIndex(for: stamped.status)
                }
                board.tasks.append(stamped)
            }
        }
    }

    func deleteTask(_ task: ProjectTask) {
        updateBoard(task.projectId) { board in
            board.tasks.removeAll { $0.id == task.id }
        }
    }

    /// Moves a task to a different column (or reorders it within one).
    ///
    /// Dropping into `.inProgress` dispatches the task to its assigned agent —
    /// this is the drag-to-start path. The status is written first so the card
    /// lands in its new column immediately, even if the dispatch is slow.
    ///
    /// A task that is In Progress is locked: its agent owns the status until
    /// the turn finishes and `advanceLinkedTaskToReview` moves it on, so user
    /// moves out of that column are ignored.
    func moveTask(_ task: ProjectTask, to status: TaskStatus, sortIndex: Double? = nil) {
        let stored = self.task(id: task.id) ?? task
        guard !stored.isStatusLocked || stored.status == status else { return }
        let previousStatus = task.status
        var moved = task
        moved.status = status
        moved.updatedAt = Date()

        updateBoard(task.projectId) { board in
            let resolvedIndex = sortIndex ?? board.appendSortIndex(for: status)
            moved.sortIndex = resolvedIndex
            if let idx = board.tasks.firstIndex(where: { $0.id == moved.id }) {
                board.tasks[idx] = moved
            } else {
                board.tasks.append(moved)
            }
        }

        guard status == .inProgress, previousStatus != .inProgress, moved.agent.isAssigned else { return }
        Task { await startTask(moved) }
    }

    // MARK: - Story CRUD


    func upsertStory(_ story: ProjectStory) {
        var stamped = story
        stamped.updatedAt = Date()
        updateBoard(story.projectId) { board in
            if let idx = board.stories.firstIndex(where: { $0.id == stamped.id }) {
                board.stories[idx] = stamped
            } else {
                board.stories.append(stamped)
            }
        }
    }

    /// Deletes a story. Its tasks are kept and orphaned back to the board root
    /// rather than deleted — losing tracked work to a container delete would be
    /// surprising.
    func deleteStory(_ story: ProjectStory) {
        updateBoard(story.projectId) { board in
            board.stories.removeAll { $0.id == story.id }
            for idx in board.tasks.indices where board.tasks[idx].storyId == story.id {
                board.tasks[idx].storyId = nil
            }
        }
    }

    // MARK: - Saved views

    func upsertSavedView(_ view: TaskSavedView, projectId: UUID) {
        updateBoard(projectId) { board in
            // The implicit default tab exists only while no view is saved.
            // Persist it before the first custom view so it doesn't vanish.
            if board.savedViews.isEmpty, view.id != TaskSavedView.defaultViewId {
                board.savedViews.append(.defaultView)
            }
            if let idx = board.savedViews.firstIndex(where: { $0.id == view.id }) {
                board.savedViews[idx] = view
            } else {
                board.savedViews.append(view)
            }
        }
    }

    func deleteSavedView(_ view: TaskSavedView, projectId: UUID) {
        updateBoard(projectId) { board in
            board.savedViews.removeAll { $0.id == view.id }
        }
    }

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

    private func chatSessionId(for task: ProjectTask) -> String? {
        guard let key = task.sessionKey else { return nil }
        let sessionId = resolveCurrentSessionId(key)
        return allSessionSummaries.contains(where: { $0.id == sessionId }) ? sessionId : nil
    }

    /// Leaves the task board for a fresh chat in `projectId`.
    func startNewChat(inProject projectId: UUID, window: WindowState) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        if window.selectedProject?.id != projectId {
            selectProject(project, in: window)
        }
        startNewChat(in: window)
    }

    // MARK: - Running a task

    /// Dispatches a task into a real chat thread using its assigned agent.
    ///
    /// Everything here reuses the normal send path: the assignment is copied
    /// onto the window's per-session override fields (the same ones the model /
    /// effort / permission pickers write), then `sendPrompt` runs exactly as it
    /// would for a typed message.
    func startTask(_ task: ProjectTask) async {
        guard let project = projects.first(where: { $0.id == task.projectId }) else {
            logger.error("startTask: no project for id \(task.projectId.uuidString, privacy: .public)")
            return
        }
        guard let window = windowForRunningTask(projectId: task.projectId) else {
            logger.error("startTask: no live window available to run the task")
            return
        }

        // Preserve the visible route: running a task from the board should not
        // yank the board out from under the user. `selectProject` /
        // `startNewChat` both clear `generalRoute` to reveal the chat, so it is
        // restored below — the thread streams in the background either way.
        let routeBeforeDispatch = window.generalRoute

        if window.selectedProject?.id != project.id {
            selectProject(project, in: window)
        }
        startNewChat(in: window)

        // Apply the agent assignment onto the per-session overrides.
        if let model = task.agent.model, !model.isEmpty {
            setSessionModel(model, provider: task.agent.provider, in: window)
        } else if let provider = task.agent.provider {
            window.sessionAgentProvider = provider
        }

        // Effort is a provider-dependent string, so validate it against the
        // resolved provider before it reaches a backend — an unloaded provider
        // reports no levels, which would otherwise reject a valid value.
        if let effort = task.agent.effort, !effort.isEmpty {
            let provider = effectiveModelSelection(in: window).provider
            await loadReasoningLevels(for: provider)
            setSessionEffort(await sanitizedEffort(effort, for: provider), in: window)
        }

        if let mode = task.agent.permissionMode {
            setSessionPermissionMode(mode, in: window)
        }
        window.sessionPlanMode = task.agent.planMode

        // Rehydrate the task's images through the same factory the composer
        // uses, so in-memory image data is materialized to disk before send.
        let attachments = task.attachments.map { Attachment(dto: $0) }
        let (resolved, tempFilePaths) = AttachmentFactory.resolvingClipboardImages(attachments)

        let storyTitle = taskBoard(for: task.projectId).story(id: task.storyId)?.title
        let displayText = task.agentPrompt(storyTitle: storyTitle)
        let fullPrompt = buildPromptWithAttachments(displayText, attachments: resolved)

        // Mark the task running before sending so the card is already in
        // In Progress while the prompt is dispatched.
        var linked = task
        linked.status = .inProgress
        upsertTask(linked)

        // `sendPrompt` dispatches the stream on a detached task and returns as
        // soon as it is running, so the route is restored here rather than in a
        // `defer` — the rename wait below can take seconds and the board should
        // already be back by then.
        _ = await sendPrompt(
            fullPrompt,
            displayText: displayText,
            attachments: resolved,
            tempFilePaths: tempFilePaths,
            in: window
        )
        window.generalRoute = routeBeforeDispatch

        // Link the thread from the key `sendPrompt` actually opened it under.
        // For a new chat that is a `pending-<streamId>` placeholder, which is
        // what the CLI rename redirects to the real session id. (The window's
        // `newSessionKey` is *not* — linking that left the task pointing at no
        // thread, so Open Chat did nothing and the session-end hook never
        // matched it to move it to Pending Review.) The link is written right
        // after dispatch, well before an agent turn can finish.
        guard let sessionKey = window.currentSessionId else {
            logger.error("[Tasks] no session opened for task \(task.id.uuidString, privacy: .public)")
            return
        }
        if var current = self.task(id: task.id) {
            current.sessionKey = sessionKey
            upsertTask(current)
        }

        // Re-link to the real CLI session id once the stream reports it.
        //
        // The `pending-…` placeholder only resolves through the in-memory
        // redirect table, which is gone after a relaunch, so wait for the
        // rename and pin the real id. `awaitSessionRename` fast-paths when
        // the redirect already landed.
        guard let realSessionId = await awaitSessionRename(pendingKey: sessionKey, timeout: 60) else {
            logger.error("[Tasks] timed out waiting for a session id for task \(task.id.uuidString, privacy: .public)")
            return
        }
        // Re-read rather than reusing `linked`: the turn may already have
        // finished and advanced the task to Pending Review, and only the
        // session link should be overwritten here.
        if var current = self.task(id: task.id), current.sessionKey != realSessionId {
            current.sessionKey = realSessionId
            upsertTask(current)
        }
    }

    /// Prefers a window already showing the task's project, then any window
    /// with no project selected, then the first live window.
    private func windowForRunningTask(projectId: UUID) -> WindowState? {
        let windows = registeredWindows()
        if let match = windows.first(where: { $0.selectedProject?.id == projectId }) { return match }
        if let idle = windows.first(where: { $0.selectedProject == nil }) { return idle }
        return windows.first
    }

    // MARK: - Run history

    /// The task's thread transcript: the live in-memory messages when they are
    /// at least as complete as what's on disk, otherwise the persisted history
    /// (the thread may never have been opened this launch). `nil` when the task
    /// has no thread to read.
    func taskRunMessages(for task: ProjectTask) async -> [ChatMessage]? {
        guard let sessionId = chatSessionId(for: task) else { return nil }
        let live = sessionStates[sessionId]?.messages ?? []
        let persisted = await persistedMessages(sessionId: sessionId) ?? []
        return live.count >= persisted.count ? live : persisted
    }

    private func persistedMessages(sessionId: String) async -> [ChatMessage]? {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionId }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else { return nil }
        return await persistence.loadFullSession(summary: summary, cwd: project.path)?.messages
    }

    /// Sends a follow-up into the task's thread in the background and puts the
    /// task back In Progress; `TaskBoardHook` returns it to Pending Review when
    /// the turn finishes, exactly like the first run. Refused while the agent
    /// is still running the task.
    @discardableResult
    func sendTaskFollowUp(_ task: ProjectTask, text: String) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let current = self.task(id: task.id), !current.isStatusLocked,
              let sessionId = chatSessionId(for: current)
        else { return false }

        // The send saves the thread from its in-memory messages, so a thread
        // not opened this launch must be hydrated first or its history would
        // be written back as just the follow-up.
        if sessionStates[sessionId]?.messages.isEmpty ?? true,
           let history = await persistedMessages(sessionId: sessionId), !history.isEmpty {
            updateState(sessionId) { $0.messages = history }
        }

        // Written directly rather than through `moveTask`: entering In Progress
        // there dispatches a brand-new run, and this continues the existing one.
        let previousStatus = current.status
        updateBoard(current.projectId) { board in
            guard let idx = board.tasks.firstIndex(where: { $0.id == current.id }) else { return }
            board.tasks[idx].status = .inProgress
            board.tasks[idx].sortIndex = board.appendSortIndex(for: .inProgress)
            board.tasks[idx].updatedAt = Date()
        }

        do {
            _ = try await sendCrossProject(
                projectId: current.projectId,
                threadId: sessionId,
                prompt: prompt,
                waitForResponse: false
            )
            return true
        } catch {
            logger.error("[Tasks] follow-up failed for task \(current.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateBoard(current.projectId) { board in
                guard let idx = board.tasks.firstIndex(where: { $0.id == current.id }) else { return }
                board.tasks[idx].status = previousStatus
                board.tasks[idx].sortIndex = board.appendSortIndex(for: previousStatus)
            }
            return false
        }
    }

    // MARK: - Completion

    /// Moves the task linked to `sessionKey` from In Progress to Pending Review.
    /// Called by `TaskBoardHook` when a turn finishes cleanly.
    ///
    /// Returns the advanced task id, or `nil` when the session owns no task.
    @discardableResult
    func advanceLinkedTaskToReview(sessionKey: String) -> UUID? {
        // Redirect-aware match: the CLI rotates the session id mid-life
        // (`pending-<uuid>` → real sid, and again on `compact_boundary`), so the
        // key recorded when the task was dispatched won't raw-match a later
        // turn's key. Same reasoning as `isSetupSession`.
        let target = resolveCurrentSessionId(sessionKey)
        for (projectId, board) in taskBoards {
            guard let idx = board.tasks.firstIndex(where: {
                guard let linked = $0.sessionKey, $0.status == .inProgress else { return false }
                return resolveCurrentSessionId(linked) == target
            }) else { continue }

            var updated = board.tasks[idx]
            updated.status = .pendingReview
            updated.updatedAt = Date()
            updateBoard(projectId) { board in
                guard let i = board.tasks.firstIndex(where: { $0.id == updated.id }) else { return }
                updated.sortIndex = board.appendSortIndex(for: .pendingReview)
                board.tasks[i] = updated
            }
            logger.info("[Tasks] advanced task \(updated.id.uuidString, privacy: .public) to pending review")
            return updated.id
        }
        return nil
    }
}

extension ProjectTask {
    /// An In Progress task that was dispatched to an agent is owned by that
    /// run: the board, forms and menus don't let the user change its status,
    /// and it moves to Pending Review when the turn finishes. A task placed in
    /// In Progress by hand (no linked thread) stays freely movable.
    var isStatusLocked: Bool { status == .inProgress && sessionKey != nil }

    /// The description is what the agent was prompted with, so it is frozen
    /// once the task has left Pending or has been dispatched.
    var isDescriptionLocked: Bool { status != .pending || sessionKey != nil }
}

// MARK: - Run turns

/// One prompt the task's thread was given and the agent's final answer to it.
struct TaskRunTurn: Identifiable, Equatable {
    let id: Int
    let prompt: String
    /// The last non-empty assistant text before the next prompt; empty while
    /// the turn is still running or when it produced no text.
    let response: String
    let didError: Bool

    /// Groups a transcript into prompt → final-response pairs. Intermediate
    /// assistant text (narration between tool calls) is dropped: the Run tab
    /// shows outcomes, the chat shows the process.
    static func turns(from messages: [ChatMessage]) -> [TaskRunTurn] {
        var turns: [TaskRunTurn] = []
        var prompt: String?
        var response = ""
        var didError = false

        func flush() {
            guard let prompt else { return }
            turns.append(TaskRunTurn(id: turns.count, prompt: prompt, response: response, didError: didError))
        }

        for message in messages {
            switch message.role {
            case .user where !message.isError:
                flush()
                prompt = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                response = ""
                didError = false
            case .assistant:
                if message.isError {
                    didError = true
                } else {
                    let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { response = text }
                }
            default:
                continue
            }
        }
        flush()
        return turns
    }
}
