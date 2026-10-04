import Foundation
import RxCodeCore
import os

extension AppState {

    // MARK: - Scheduled Tasks

    func loadScheduledTasksFromDisk() async {
        scheduledTasks = await persistence.loadScheduledTasks()
        scheduledTaskRuns = ScheduledTaskRun.pruned(
            ScheduledTaskRun.restored(await persistence.loadScheduledTaskRuns())
        )
    }

    /// Inserts `task`, or replaces the stored task with the same id, and
    /// persists the list.
    func upsertScheduledTask(_ task: ScheduledTask) {
        var task = task
        task.updatedAt = .now
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx] = task
        } else {
            scheduledTasks.append(task)
            AnalyticsService.shared.log(.scheduledTaskCreated)
        }
        saveScheduledTasks()
    }

    func setScheduledTaskEnabled(id: UUID, _ enabled: Bool) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == id }),
              scheduledTasks[idx].isEnabled != enabled
        else { return }
        scheduledTasks[idx].isEnabled = enabled
        scheduledTasks[idx].updatedAt = .now
        saveScheduledTasks()
    }

    func deleteScheduledTask(id: UUID) {
        scheduledTasks.removeAll { $0.id == id }
        saveScheduledTasks()
        if scheduledTaskRuns.contains(where: { $0.taskId == id }) {
            scheduledTaskRuns.removeAll { $0.taskId == id }
            saveScheduledTaskRuns()
        }
    }

    /// Drops every scheduled task of a project being removed.
    func deleteScheduledTasks(projectId: UUID) {
        guard scheduledTasks.contains(where: { $0.projectId == projectId }) else { return }
        let ids = Set(scheduledTasks.filter { $0.projectId == projectId }.map(\.id))
        scheduledTasks.removeAll { $0.projectId == projectId }
        saveScheduledTasks()
        scheduledTaskRuns.removeAll { ids.contains($0.taskId) }
        saveScheduledTaskRuns()
    }

    /// The agent a run of `task` uses: its own model, else the default task
    /// agent resolved at run time.
    func resolvedAgent(for task: ScheduledTask) -> TaskAgentConfig {
        task.agent.isAssigned ? task.agent : defaultTaskAgent()
    }

    // MARK: - Running

    /// Starts one run of `task` in a new chat thread of its project (or Chat
    /// when it has none), with its model and notification setting, and
    /// records it in the task's run history. Returns the session key the run
    /// opened, or `nil` when it couldn't start.
    @discardableResult
    func runScheduledTask(_ task: ScheduledTask, trigger: ScheduledTaskRun.Trigger = .schedule) async -> String? {
        let project: Project
        if let projectId = task.projectId {
            guard let found = projects.first(where: { $0.id == projectId }) else {
                logger.error("[Scheduled] no project for task \(task.id.uuidString, privacy: .public)")
                recordScheduledTaskRun(ScheduledTaskRun(
                    taskId: task.id, projectId: task.projectId, trigger: trigger,
                    status: .failed, finishedAt: .now,
                    errorMessage: String(localized: "The task's project no longer exists.")
                ))
                return nil
            }
            project = found
        } else {
            project = globalChatProject
        }
        // Like board tasks, the stream only needs a background window.
        let window = WindowState()
        window.selectedProject = project
        let agent = resolvedAgent(for: task)
        if let model = agent.model, !model.isEmpty {
            setSessionModel(model, provider: agent.provider, in: window)
        } else if let provider = agent.provider {
            window.sessionAgentProvider = provider
        }
        if let effort = agent.effort, !effort.isEmpty {
            let provider = effectiveModelSelection(in: window).provider
            await loadReasoningLevels(for: provider)
            setSessionEffort(await sanitizedEffort(effort, for: provider), in: window)
        }
        if let mode = agent.permissionMode {
            setSessionPermissionMode(mode, in: window)
        }

        let startedAt = Date.now
        _ = await sendPrompt(task.runPrompt, displayText: task.prompt, in: window)
        guard let sessionKey = window.currentSessionId else {
            logger.error("[Scheduled] no session opened for task \(task.id.uuidString, privacy: .public)")
            recordScheduledTaskRun(ScheduledTaskRun(
                taskId: task.id, projectId: task.projectId, trigger: trigger,
                status: .failed, startedAt: startedAt, finishedAt: .now,
                errorMessage: String(localized: "The agent run couldn't start.")
            ))
            return nil
        }
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx].lastRunAt = startedAt
            saveScheduledTasks()
        }
        let run = ScheduledTaskRun(
            taskId: task.id, projectId: task.projectId, sessionKey: sessionKey,
            trigger: trigger, startedAt: startedAt
        )
        recordScheduledTaskRun(run)
        Task { [weak self] in
            await self?.finishScheduledTaskRun(id: run.id, sessionKey: sessionKey)
        }
        if task.notification != .none {
            // The run owns its notification, so the automatic briefing
            // notification leaves it alone.
            scheduledRunNotificationSessions[sessionKey] = task.notification
        }
        if task.notification == .completionReport {
            Task { [weak self] in
                await self?.sendScheduledTaskCompletionReport(task, sessionKey: sessionKey, startedAt: startedAt)
            }
        }
        return sessionKey
    }

    /// The notification setting of the scheduled run behind any of
    /// `sessionKeys`, matching across the CLI session rename.
    func scheduledRunNotification(forSessions sessionKeys: Set<String>) -> ScheduledTaskNotification? {
        let resolved = Set(sessionKeys.map(resolveCurrentSessionId))
        return scheduledRunNotificationSessions.first { key, _ in
            sessionKeys.contains(key) || resolved.contains(resolveCurrentSessionId(key))
        }?.value
    }

    /// Waits for the run to end, then emails its final message as the
    /// completion report — unless the run already sent a notification.
    private func sendScheduledTaskCompletionReport(_ task: ScheduledTask, sessionKey: String, startedAt: Date) async {
        let sessionKeys = notificationSessionKeys(sessionKey)
        await waitForSessionsToFinish(sessionKeys)
        let resolved = resolveCurrentSessionId(sessionKey)
        let finalMessage = sessionStates[resolved]?.messages
            .last { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .content
        let report = task.completionReport(finalMessage: finalMessage)

        guard isSignedIn else {
            await recordNotification(NotificationRecord(
                source: .scheduledTask, status: .failed, subject: report.subject,
                projectId: task.projectId, sessionKey: sessionKey,
                errorMessage: String(localized: "Sign in to Autopilot to send notifications.")
            ))
            return
        }
        if await notificationStore.hasSent(fromSessions: sessionKeys, since: startedAt) {
            await recordNotification(NotificationRecord(
                source: .scheduledTask, status: .skipped, subject: report.subject,
                projectId: task.projectId, sessionKey: sessionKey,
                reason: String(localized: "The agent run already sent a notification.")
            ))
            return
        }
        let base = task.projectId
            .flatMap { id in projects.first(where: { $0.id == id }) }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        await sendNotification(
            subject: report.subject,
            body: report.body,
            format: .markdown,
            imageBaseURL: base,
            recipient: briefingNotificationSettings.recipient,
            source: .scheduledTask,
            projectId: task.projectId,
            sessionKey: sessionKey,
            reason: String(localized: "Completion report for the scheduled task.")
        )
    }

    // MARK: - Run History

    /// Runs of the task `taskId`, newest first.
    func scheduledTaskRuns(for taskId: UUID) -> [ScheduledTaskRun] {
        scheduledTaskRuns.filter { $0.taskId == taskId }
    }

    /// Whether a run of the task `taskId` is still in flight.
    func isScheduledTaskRunning(_ taskId: UUID) -> Bool {
        scheduledTaskRuns.contains { $0.taskId == taskId && $0.status == .running }
    }

    /// The live session id of `run`'s thread, following CLI session renames.
    func resolvedSessionKey(for run: ScheduledTaskRun) -> String? {
        run.sessionKey.map(resolveCurrentSessionId)
    }

    /// The messages of `run`'s thread: live from memory when loaded, else
    /// read from disk. `nil` when the thread no longer exists.
    func scheduledTaskRunMessages(_ run: ScheduledTaskRun) async -> [ChatMessage]? {
        guard let sessionId = resolvedSessionKey(for: run) else { return nil }
        if let messages = sessionStates[sessionId]?.messages, !messages.isEmpty {
            return messages
        }
        let project = sessionProject(id: run.projectId ?? Project.globalChatID) ?? globalChatProject
        let summary = summaryFor(sessionId: sessionId, projectId: project.id)
        guard let session = await persistence.loadFullSession(summary: summary, cwd: project.path) else {
            return nil
        }
        return cleanLoadedMessages(session.messages)
    }

    /// Whether the agent in `run`'s thread is responding right now, whether
    /// to the scheduled prompt or a follow-up.
    func isScheduledTaskRunStreaming(_ run: ScheduledTaskRun) -> Bool {
        guard let sessionId = resolvedSessionKey(for: run) else { return false }
        return sessionStates[sessionId]?.isStreaming == true
    }

    /// Continues `run`'s thread with `text`, so the user can chat with the
    /// agent about the run. Returns whether the message was sent.
    func sendScheduledTaskRunFollowUp(_ run: ScheduledTaskRun, text: String) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let sessionId = resolvedSessionKey(for: run),
              !isScheduledTaskRunStreaming(run)
        else { return false }

        // The send saves the thread from its in-memory messages, so a thread
        // not opened this launch must be hydrated first or its history would
        // be written back as just the follow-up.
        if sessionStates[sessionId]?.messages.isEmpty ?? true,
           let history = await scheduledTaskRunMessages(run), !history.isEmpty {
            updateState(sessionId) { $0.messages = history }
        }

        do {
            _ = try await sendCrossProject(
                projectId: run.projectId,
                threadId: sessionId,
                prompt: prompt,
                displayText: prompt,
                waitForResponse: false
            )
            return true
        } catch {
            logger.error("[Scheduled] follow-up failed for run \(run.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func recordScheduledTaskRun(_ run: ScheduledTaskRun) {
        scheduledTaskRuns.insert(run, at: 0)
        scheduledTaskRuns = ScheduledTaskRun.pruned(scheduledTaskRuns)
        saveScheduledTaskRuns()
    }

    /// Waits for the run's thread to stop streaming, then stores how it
    /// ended along with its final message.
    private func finishScheduledTaskRun(id: UUID, sessionKey: String) async {
        // Let the first turn start streaming before polling.
        try? await Task.sleep(for: .seconds(2))
        while sessionStates[resolveCurrentSessionId(sessionKey)]?.isStreaming == true {
            try? await Task.sleep(for: .seconds(3))
        }
        let resolved = resolveCurrentSessionId(sessionKey)
        let messages = sessionStates[resolved]?.messages ?? []
        let lastError = messages.last.flatMap { $0.isError ? $0.content : nil }
        let finalMessage = messages
            .last { $0.role == .assistant && !$0.isError && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .content

        guard let idx = scheduledTaskRuns.firstIndex(where: { $0.id == id }) else { return }
        scheduledTaskRuns[idx].sessionKey = resolved
        scheduledTaskRuns[idx].finishedAt = .now
        scheduledTaskRuns[idx].summary = ScheduledTaskRun.makeSummary(finalMessage)
        if let lastError {
            scheduledTaskRuns[idx].status = .failed
            scheduledTaskRuns[idx].errorMessage = ScheduledTaskRun.makeSummary(lastError)
        } else {
            scheduledTaskRuns[idx].status = .succeeded
        }
        saveScheduledTaskRuns()
    }

    private func saveScheduledTaskRuns() {
        let runs = scheduledTaskRuns
        Task { [persistence, logger] in
            do {
                try await persistence.saveScheduledTaskRuns(runs)
            } catch {
                logger.error("Failed to save scheduled task runs: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Agent Proposals

    /// Queues `proposal` for the user to confirm and waits for their decision.
    /// Returns the task as added (possibly edited by the user), or `nil` when
    /// they cancel or the waiting call is cancelled.
    func confirmScheduledTaskProposal(_ proposal: ScheduledTask) async -> ScheduledTask? {
        let id = proposal.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                scheduledTaskProposalContinuations[id] = continuation
                scheduledTaskProposals.append(proposal)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveScheduledTaskProposal(id: id, with: nil)
            }
        }
    }

    /// Settles the proposal `id`: adds `task` when non-nil and resumes the
    /// waiting tool call. A no-op for proposals already settled, so the sheet
    /// can resolve on both its buttons and its disappearance.
    func resolveScheduledTaskProposal(id: UUID, with task: ScheduledTask?) {
        guard let continuation = scheduledTaskProposalContinuations.removeValue(forKey: id) else { return }
        scheduledTaskProposals.removeAll { $0.id == id }
        if let task {
            upsertScheduledTask(task)
        }
        continuation.resume(returning: task)
    }

    private func saveScheduledTasks() {
        let tasks = scheduledTasks
        Task { [persistence, logger] in
            do {
                try await persistence.saveScheduledTasks(tasks)
            } catch {
                logger.error("Failed to save scheduled tasks: \(error.localizedDescription)")
            }
        }
    }
}
