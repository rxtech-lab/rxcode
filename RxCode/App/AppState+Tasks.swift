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

    /// Moves agent-owned tasks out of their chat column, as if their session
    /// had stopped. Run once at launch: nothing is streaming yet, so any such
    /// task belongs to a run the last app session was cut off from, and its
    /// session-end hook will never fire. Without this the task would stay
    /// locked in its chat column.
    func releaseInterruptedTasks() {
        for (projectId, board) in taskBoards where board.tasks.contains(where: board.isStatusLocked) {
            updateBoard(projectId) { board in
                for idx in board.tasks.indices where board.isStatusLocked(board.tasks[idx]) {
                    guard let target = board.releaseTarget(for: board.tasks[idx]) else { continue }
                    board.tasks[idx].status = target
                    board.tasks[idx].sortIndex = board.appendSortIndex(for: target)
                    board.tasks[idx].updatedAt = Date()
                }
            }
        }
    }

    /// Whether the task's agent owns its column right now; see
    /// `TaskBoard.isStatusLocked`.
    func isStatusLocked(_ task: ProjectTask) -> Bool {
        taskBoard(for: task.projectId).isStatusLocked(self.task(id: task.id) ?? task)
    }

    /// The column definition a task currently sits in.
    func column(for task: ProjectTask) -> TaskColumn {
        taskBoard(for: task.projectId).column(for: task.status)
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
        allTasks(projectFilter: projectFilter, savedView: savedView).filter {
            taskBoard(for: $0.projectId).resolvedStatus(of: $0) == status
        }
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
    private static let defaultTaskProviderKey = "taskDefaultAgentProvider"
    private static let defaultTaskModelKey = "taskDefaultAgentModel"
    private static let autoClassifyTasksKey = "taskAutoClassifyQuickAdd"

    /// The agent a new task starts with: the one chosen in Settings → Tasks,
    /// else the model last picked in a task form, else the app's current
    /// model selection.
    func defaultTaskAgent() -> TaskAgentConfig {
        if let configured = configuredDefaultTaskAgent() {
            return configured
        }
        if let provider = workspaceDefaults.string(for: Self.lastTaskProviderKey).flatMap(AgentProvider.init(rawValue:)),
           let model = workspaceDefaults.string(for: Self.lastTaskModelKey), !model.isEmpty {
            return TaskAgentConfig(provider: provider, model: model)
        }
        return TaskAgentConfig(provider: selectedAgentProvider, model: selectedModel)
    }

    /// The default agent set in Settings, or `nil` for "last used".
    func configuredDefaultTaskAgent() -> TaskAgentConfig? {
        guard let provider = workspaceDefaults.string(for: Self.defaultTaskProviderKey).flatMap(AgentProvider.init(rawValue:)),
              let model = workspaceDefaults.string(for: Self.defaultTaskModelKey), !model.isEmpty
        else { return nil }
        return TaskAgentConfig(provider: provider, model: model)
    }

    /// Pins the default task agent. `nil` goes back to "last used".
    func setConfiguredDefaultTaskAgent(provider: AgentProvider?, model: String?) {
        workspaceDefaults.set(provider?.rawValue, for: Self.defaultTaskProviderKey)
        workspaceDefaults.set(model, for: Self.defaultTaskModelKey)
    }

    /// Whether quick-added tasks are sent to the default agent to summarize a
    /// title from what was typed and to fill in type, priority, tags, version
    /// and milestone. On unless turned off.
    var autoClassifiesQuickAddedTasks: Bool {
        get { workspaceDefaults.bool(for: Self.autoClassifyTasksKey, default: true) }
        set { workspaceDefaults.set(newValue, for: Self.autoClassifyTasksKey) }
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
    /// Dropping into a column that triggers a chat dispatches the task to its
    /// assigned agent — this is the drag-to-start path. The status is written
    /// first so the card lands in its new column immediately, even if the
    /// dispatch is slow.
    ///
    /// A dispatched task in a chat column is locked: its agent owns the status
    /// until the turn finishes and the column's session-stop trigger moves it
    /// on (`applyTaskTrigger`), so user moves out of that column are ignored.
    func moveTask(_ task: ProjectTask, to status: TaskStatus, sortIndex: Double? = nil) {
        let stored = self.task(id: task.id) ?? task
        let board = taskBoard(for: task.projectId)
        guard !board.isStatusLocked(stored) || board.resolvedStatus(of: stored) == status else { return }
        let previousColumn = board.column(for: stored.status)
        let targetColumn = board.column(for: status)
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

        guard targetColumn.triggersChat, !previousColumn.triggersChat, moved.agent.isAssigned else { return }
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

    /// Tab drag-and-drop: `view` takes `target`'s slot. Persists the implicit
    /// default tab too, since the order now lives in `savedViews`.
    func reorderSavedView(_ view: UUID, onto target: UUID, projectId: UUID) {
        updateBoard(projectId) { board in
            guard let order = board.viewOrder(moving: view, to: target) else { return }
            board.savedViews = order
        }
    }

    func deleteSavedView(_ view: TaskSavedView, projectId: UUID) {
        updateBoard(projectId) { board in
            board.savedViews.removeAll { $0.id == view.id }
        }
    }

    // MARK: - Labels and types

    /// Sets a tag's color, creating the label entry if the tag had none.
    func setLabelColor(_ tag: String, colorHex: String, projectId: UUID) {
        updateBoard(projectId) { board in
            if let idx = board.labels.firstIndex(where: { $0.name == tag }) {
                board.labels[idx].colorHex = colorHex
            } else {
                board.labels.append(TaskLabel(name: tag, colorHex: colorHex))
            }
        }
    }

    /// Adds a label so it can be picked before any item uses it.
    func addLabel(_ name: String, colorHex: String, projectId: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !taskBoard(for: projectId).allTags.contains(trimmed) else { return }
        setLabelColor(trimmed, colorHex: colorHex, projectId: projectId)
    }

    /// Renames a tag everywhere it is used, and on its label and saved views,
    /// so the rename behaves like editing a GitHub label.
    func renameLabel(_ tag: String, to newName: String, projectId: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag else { return }
        updateBoard(projectId) { board in
            func rename(_ tags: [String]) -> [String] {
                var result: [String] = []
                for existing in tags {
                    let renamed = existing == tag ? trimmed : existing
                    if !result.contains(renamed) { result.append(renamed) }
                }
                return result
            }
            for idx in board.tasks.indices { board.tasks[idx].tags = rename(board.tasks[idx].tags) }
            for idx in board.stories.indices { board.stories[idx].tags = rename(board.stories[idx].tags) }
            for idx in board.savedViews.indices { board.savedViews[idx].tags = rename(board.savedViews[idx].tags) }
            // Merging into an existing label keeps the target's color.
            if board.labels.contains(where: { $0.name == trimmed }) {
                board.labels.removeAll { $0.name == tag }
            } else if let idx = board.labels.firstIndex(where: { $0.name == tag }) {
                board.labels[idx].name = trimmed
            }
        }
    }

    /// Deletes a tag from every story, task and saved view, along with its color.
    func deleteLabel(_ tag: String, projectId: UUID) {
        updateBoard(projectId) { board in
            for idx in board.tasks.indices { board.tasks[idx].tags.removeAll { $0 == tag } }
            for idx in board.stories.indices { board.stories[idx].tags.removeAll { $0 == tag } }
            for idx in board.savedViews.indices { board.savedViews[idx].tags.removeAll { $0 == tag } }
            board.labels.removeAll { $0.name == tag }
        }
    }

    /// Renames a version on every story, task and saved view using it.
    /// Renaming onto an existing version merges the two.
    func renameVersion(_ version: String, to newName: String, projectId: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != version else { return }
        updateBoard(projectId) { board in
            for idx in board.tasks.indices where board.tasks[idx].version == version {
                board.tasks[idx].version = trimmed
            }
            for idx in board.stories.indices where board.stories[idx].version == version {
                board.stories[idx].version = trimmed
            }
            for idx in board.savedViews.indices where board.savedViews[idx].version == version {
                board.savedViews[idx].version = trimmed
            }
        }
    }

    /// Clears a version from every story, task and saved view using it.
    func deleteVersion(_ version: String, projectId: UUID) {
        updateBoard(projectId) { board in
            for idx in board.tasks.indices where board.tasks[idx].version == version {
                board.tasks[idx].version = nil
            }
            for idx in board.stories.indices where board.stories[idx].version == version {
                board.stories[idx].version = nil
            }
            for idx in board.savedViews.indices where board.savedViews[idx].version == version {
                board.savedViews[idx].version = nil
            }
        }
    }

    /// Renames a milestone on every story and task using it. Renaming onto an
    /// existing milestone merges the two.
    func renameMilestone(_ milestone: String, to newName: String, projectId: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != milestone else { return }
        updateBoard(projectId) { board in
            for idx in board.tasks.indices where board.tasks[idx].milestone == milestone {
                board.tasks[idx].milestone = trimmed
            }
            for idx in board.stories.indices where board.stories[idx].milestone == milestone {
                board.stories[idx].milestone = trimmed
            }
        }
    }

    /// Clears a milestone from every story and task using it.
    func deleteMilestone(_ milestone: String, projectId: UUID) {
        updateBoard(projectId) { board in
            for idx in board.tasks.indices where board.tasks[idx].milestone == milestone {
                board.tasks[idx].milestone = nil
            }
            for idx in board.stories.indices where board.stories[idx].milestone == milestone {
                board.stories[idx].milestone = nil
            }
        }
    }

    /// Inserts or replaces an item type. The first edit persists the default
    /// types, so editing one doesn't make the others disappear.
    func upsertItemType(_ type: TaskItemType, projectId: UUID) {
        updateBoard(projectId) { board in
            if board.itemTypes.isEmpty {
                board.itemTypes = TaskItemType.defaults
            }
            if let idx = board.itemTypes.firstIndex(where: { $0.id == type.id }) {
                board.itemTypes[idx] = type
            } else {
                board.itemTypes.append(type)
            }
        }
    }

    /// Deletes an item type and clears it from every story and task using it.
    func deleteItemType(_ type: TaskItemType, projectId: UUID) {
        updateBoard(projectId) { board in
            if board.itemTypes.isEmpty {
                board.itemTypes = TaskItemType.defaults
            }
            board.itemTypes.removeAll { $0.id == type.id }
            for idx in board.tasks.indices where board.tasks[idx].typeId == type.id {
                board.tasks[idx].typeId = nil
            }
            for idx in board.stories.indices where board.stories[idx].typeId == type.id {
                board.stories[idx].typeId = nil
            }
        }
    }

    // MARK: - Quick add

    /// A blank task draft parented to `story`, for the forms that open on a
    /// new task instead of creating one outright. Matches what `quickAddTask`
    /// builds: the board's first column, and the story's version and milestone.
    func newTaskDraft(inStory story: ProjectStory) -> ProjectTask {
        ProjectTask(
            projectId: story.projectId,
            storyId: story.id,
            title: "",
            status: taskBoard(for: story.projectId).firstColumn.id,
            version: story.version,
            milestone: story.milestone
        )
    }

    /// Creates a task in the board's first column from a line of free text.
    ///
    /// The text is the *description*: it is what the agent is eventually asked
    /// to do, so it is kept whole rather than squeezed into a title. The title
    /// starts as a local shortening of it and — unless turned off in
    /// Settings → Tasks — the default agent rewrites it into a summary and
    /// fills in the remaining properties in the background. Version and
    /// milestone are inherited from the story.
    @discardableResult
    func quickAddTask(text: String, projectId: UUID, storyId: UUID?) -> ProjectTask {
        let details = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let story = taskBoard(for: projectId).story(id: storyId)
        let provisionalTitle = TaskTitleSuggestion.fallback(from: details)
        let task = ProjectTask(
            projectId: projectId,
            storyId: storyId,
            title: provisionalTitle,
            details: details,
            status: taskBoard(for: projectId).firstColumn.id,
            version: story?.version,
            milestone: story?.milestone,
            agent: defaultTaskAgent()
        )
        upsertTask(task)
        if autoClassifiesQuickAddedTasks {
            classifyingTaskIds.insert(task.id)
            Task { await enrichTask(id: task.id, provisionalTitle: provisionalTitle) }
        }
        return task
    }

    /// Asks the default agent for a title and for the task's properties, and
    /// fills in the ones still empty. The task is re-read after the (slow)
    /// calls, so edits made meanwhile are kept and a deleted task is left
    /// alone; the title is only replaced while it is still the placeholder
    /// quick add derived, never once the user has typed their own.
    func enrichTask(id: UUID, provisionalTitle: String?) async {
        defer { classifyingTaskIds.remove(id) }
        guard let task = task(id: id) else { return }
        // Independent prompts: run them together rather than paying for two
        // round trips in a row while the card sits under a spinner.
        async let title = suggestTitle(details: task.details, storyTitle: storyTitle(for: task))
        async let classification = suggestClassification(for: task)
        let (suggestedTitle, suggestion) = await (title, classification)

        guard var current = self.task(id: id) else { return }
        let before = current
        if let suggestedTitle, current.title.isEmpty || current.title == provisionalTitle {
            current.title = suggestedTitle
        }
        suggestion?.apply(to: &current, board: taskBoard(for: current.projectId))
        if current != before {
            upsertTask(current)
        }
    }

    /// The default agent's suggested properties for `task`, which may be an
    /// unsaved draft. `nil` when no agent could answer.
    func suggestClassification(for task: ProjectTask) async -> TaskClassification? {
        let board = taskBoard(for: task.projectId)
        let prompt = TaskClassification.prompt(
            title: task.title,
            details: task.details,
            storyTitle: board.story(id: task.storyId)?.title,
            board: board
        )
        guard let raw = await runTaskAgentCompletion(prompt: prompt) else {
            logger.warning("[Tasks] no classification response for task \(task.id.uuidString, privacy: .public)")
            return nil
        }
        guard let suggestion = TaskClassification.parse(raw) else {
            logger.warning("[Tasks] unparseable classification for task \(task.id.uuidString, privacy: .public)")
            return nil
        }
        return suggestion
    }

    /// A one-line title summarizing `details`, from the default task agent.
    /// Takes the text rather than a record so an unsaved draft — and a story
    /// as much as a task — can ask for one. `nil` when the description is
    /// empty or no agent could answer.
    func suggestTitle(details: String, storyTitle: String?) async -> String? {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = TaskTitleSuggestion.prompt(details: trimmed, storyTitle: storyTitle)
        guard let raw = await runTaskAgentCompletion(prompt: prompt) else {
            logger.warning("[Tasks] no title response")
            return nil
        }
        return TaskTitleSuggestion.parse(raw)
    }

    /// The title of the story a task belongs to, if any.
    private func storyTitle(for task: ProjectTask) -> String? {
        taskBoard(for: task.projectId).story(id: task.storyId)?.title
    }

    /// Runs a one-shot task prompt on the default task agent. ACP clients
    /// have no one-shot mode, so they fall back to a cheap Claude model, the
    /// same way the hook condition gate does.
    private func runTaskAgentCompletion(prompt: String) async -> String? {
        let agent = defaultTaskAgent()
        switch agent.provider ?? selectedAgentProvider {
        case .claudeCode:
            return await claude.generatePlainSummary(prompt: prompt, model: agent.model ?? "haiku", limit: 2000)
        case .codex:
            return await codex.generateCodexPlainSummary(prompt: prompt, model: agent.model)
        case .acp:
            return await claude.generatePlainSummary(prompt: prompt, model: "haiku", limit: 2000)
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
    /// Everything here reuses the normal send path through a background window:
    /// the assignment is copied onto its per-session override fields, then
    /// `sendPrompt` runs exactly as it would for a typed message.
    func startTask(_ task: ProjectTask) async {
        guard let project = projects.first(where: { $0.id == task.projectId }) else {
            logger.error("startTask: no project for id \(task.projectId.uuidString, privacy: .public)")
            return
        }
        // The stream only needs session context, not a visible window. Using
        // the board's window here briefly reveals the new chat before the
        // route can be restored, and also replaces its current chat selection.
        let window = WindowState()
        window.selectedProject = project

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

        let board = taskBoard(for: task.projectId)
        let displayText = task.agentPrompt(
            storyTitle: board.story(id: task.storyId)?.title,
            typeName: board.itemType(id: task.typeId)?.name
        )
        let fullPrompt = buildPromptWithAttachments(displayText, attachments: resolved)

        // Mark the task running before sending so the card already sits in a
        // chat column while the prompt is dispatched. A task started from a
        // non-chat column ("Run with Agent") goes to the first chat column.
        var linked = task
        if !board.column(for: task.status).triggersChat, let chatColumn = board.firstChatColumn {
            linked.status = chatColumn.id
        }
        upsertTask(linked)

        // `sendPrompt` dispatches the stream on a detached task and returns as
        // soon as it is running. The background window keeps the stream's
        // session context alive while the board remains on screen.
        _ = await sendPrompt(
            fullPrompt,
            displayText: displayText,
            attachments: resolved,
            tempFilePaths: tempFilePaths,
            in: window
        )

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

    // MARK: - Column triggers

    /// Moves the task linked to `sessionKey` to wherever its current column
    /// routes `event` (`TaskColumn.target(for:)`). Called by `TaskBoardHook`
    /// when the thread stops or is reviewed. Trigger moves never dispatch a
    /// new run — only a user drop into a chat column does.
    ///
    /// Without `sessionContinues` a card is not routed into a chat column: it
    /// would be agent-locked there with no running turn left to release it.
    ///
    /// Returns the moved task id, or `nil` when the session owns no task or its
    /// column has no target for the event.
    @discardableResult
    func applyTaskTrigger(_ event: TaskTriggerEvent, sessionKey: String, sessionContinues: Bool = false) -> UUID? {
        // Redirect-aware match: the CLI rotates the session id mid-life
        // (`pending-<uuid>` → real sid, and again on `compact_boundary`), so the
        // key recorded when the task was dispatched won't raw-match a later
        // turn's key. Same reasoning as `isSetupSession`.
        let resolvedKey = resolveCurrentSessionId(sessionKey)
        for (projectId, board) in taskBoards {
            guard let task = board.tasks.first(where: {
                guard let linked = $0.sessionKey else { return false }
                return resolveCurrentSessionId(linked) == resolvedKey
            }) else { continue }

            guard let target = board.triggerTarget(for: task, event: event),
                  sessionContinues || !board.column(for: target).triggersChat
            else { return nil }

            updateBoard(projectId) { board in
                guard let i = board.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                board.tasks[i].status = target
                board.tasks[i].sortIndex = board.appendSortIndex(for: target)
                board.tasks[i].updatedAt = Date()
            }
            logger.info("[Tasks] \(event.rawValue, privacy: .public) moved task \(task.id.uuidString, privacy: .public) to \(target.rawValue, privacy: .public)")
            return task.id
        }
        return nil
    }

    // MARK: - Columns

    /// Inserts or replaces a column. The first edit persists the default
    /// columns so the board stops following `TaskColumn.defaults`.
    func upsertColumn(_ column: TaskColumn, projectId: UUID) {
        updateBoard(projectId) { board in
            if board.columns.isEmpty { board.columns = TaskColumn.defaults }
            if let idx = board.columns.firstIndex(where: { $0.id == column.id }) {
                board.columns[idx] = column
            } else {
                board.columns.append(column)
            }
        }
    }

    /// Replaces the column order with `order` (ids of the existing columns).
    func reorderColumns(_ order: [TaskStatus], projectId: UUID) {
        updateBoard(projectId) { board in
            let current = board.effectiveColumns
            let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            var reordered = order.compactMap { byId[$0] }
            reordered += current.filter { !order.contains($0.id) }
            board.columns = reordered
        }
    }

    /// Deletes a column, moving its tasks to `destination` (default: the first
    /// remaining column). Triggers that routed cards into it route them to
    /// `destination` instead, so the board's flow survives; saved-view filters
    /// drop it. The last column can't be deleted.
    func deleteColumn(_ column: TaskColumn, projectId: UUID, moveTasksTo destination: TaskStatus? = nil) {
        updateBoard(projectId) { board in
            var remaining = board.effectiveColumns.filter { $0.id != column.id }
            guard !remaining.isEmpty else { return }
            let target = destination.flatMap { id in remaining.first { $0.id == id }?.id } ?? remaining[0].id

            for idx in remaining.indices {
                for event in TaskTriggerEvent.allCases where remaining[idx].target(for: event) == column.id {
                    remaining[idx].setTarget(remaining[idx].id == target ? nil : target, for: event)
                }
            }
            board.columns = remaining

            for idx in board.tasks.indices where board.tasks[idx].status == column.id {
                board.tasks[idx].status = target
                board.tasks[idx].sortIndex = board.appendSortIndex(for: target)
                board.tasks[idx].updatedAt = Date()
            }
            for idx in board.savedViews.indices {
                board.savedViews[idx].statuses.removeAll { $0 == column.id }
            }
        }
    }
}

extension ProjectTask {
    /// The description is what the agent was prompted with, so it is frozen
    /// once the task has been dispatched.
    var isDescriptionLocked: Bool { sessionKey != nil }
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
                prompt = promptText(of: message)
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

    /// A user message's text, led by its attachments as the `[Attached …]` /
    /// `[Link: …]` lines `TaskPromptContent` renders as chips. The chat stores
    /// follow-up attachments beside the text rather than in it, so they're
    /// added back here unless the text already carries them.
    private static func promptText(of message: ChatMessage) -> String {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = message.attachmentPaths.compactMap { info -> String? in
            switch info.type {
            case "image", "file": "[Attached \(info.type): \(info.path)]"
            case "link": "[Link: \(info.path)]"
            default: nil
            }
        }
        .filter { !content.contains($0) }
        guard !references.isEmpty else { return content }
        return (references + [content]).joined(separator: "\n")
    }
}
