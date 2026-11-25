import Foundation
import os
import RxCodeCore

// MARK: - Agents: subagents, background tasks and their reports

extension AppState {
    /// Longest a subagent may run before it is stopped.
    static let agentSubagentTimeout: Duration = .seconds(4 * 3600)

    func agentJob(id: UUID) -> AgentJob? {
        agentJobs.first { $0.id == id }
    }

    func agentJobs(for agentId: UUID) -> [AgentJob] {
        agentJobs.filter { $0.agentId == agentId }.sorted { $0.createdAt > $1.createdAt }
    }

    private func updateAgentJob(_ id: UUID, _ change: (inout AgentJob) -> Void) {
        guard let index = agentJobs.firstIndex(where: { $0.id == id }) else { return }
        change(&agentJobs[index])
        persistAgentHub()
    }

    private func recordAgentJob(_ job: AgentJob) {
        agentJobs.insert(job, at: 0)
        agentJobs = AgentJob.pruned(agentJobs)
        persistAgentHub()
    }

    // MARK: Subagents

    /// Queues a subagent job and starts it in the background. Returns at once.
    @discardableResult
    func spawnSubagent(
        agentId: UUID,
        title: String,
        prompt: String,
        config: TaskAgentConfig? = nil,
        parentSessionId: String?
    ) throws -> AgentJob {
        guard agentProfile(id: agentId) != nil else { throw AgentHubError.unknownAgent }
        let job = AgentJob(
            agentId: agentId, kind: .subagent, title: title, prompt: prompt,
            parentSessionId: parentSessionId.map(resolveCurrentSessionId),
            agent: config ?? TaskAgentConfig()
        )
        recordAgentJob(job)
        agentJobTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            _ = await self.launchSubagentJob(job.id)
            await self.monitorSubagentJob(job.id)
        }
        return job
    }

    /// Opens the subagent's thread and sends its prompt. Returns the job as
    /// launched, or `nil` when it could not start (the job is then failed).
    func launchSubagentJob(_ jobId: UUID) async -> AgentJob? {
        guard let job = agentJob(id: jobId), job.status == .queued,
              let agent = agentProfile(id: job.agentId) else { return nil }
        updateAgentJob(jobId) {
            $0.status = .running
            $0.startedAt = .now
        }
        let config = job.agent.isAssigned ? job.agent : resolvedAgentConfig(agent)
        do {
            try await ensureAgentWorkingDirectory(agent)
            let result = try await sendCrossProject(
                projectId: agent.subagentProjectId,
                threadId: nil,
                prompt: job.prompt,
                displayText: job.prompt,
                agentProvider: config.provider,
                model: config.model,
                effort: config.effort,
                permissionMode: config.permissionMode,
                waitForResponse: false,
                timeoutSeconds: 60,
                parentThreadId: job.parentSessionId,
                threadLabel: AgentJob.subagentThreadLabel
            )
            if let error = result.error {
                await finishAgentJob(jobId, status: .failed, summary: nil, error: error)
                return nil
            }
            updateAgentJob(jobId) { $0.sessionKey = result.threadId }
            logger.info("[Agents] subagent job=\(jobId.uuidString, privacy: .public) thread=\(result.threadId, privacy: .public)")
            // Cancelled while the thread was being opened: stop what just started.
            if agentJob(id: jobId)?.status == .cancelled {
                await stopAgentThread(result.threadId)
                return nil
            }
            return agentJob(id: jobId)
        } catch {
            await finishAgentJob(jobId, status: .failed, summary: nil, error: error.localizedDescription)
            return nil
        }
    }

    /// Waits for the subagent's thread to stop streaming, then records how it
    /// ended and reports to the agent.
    func monitorSubagentJob(_ jobId: UUID) async {
        guard let job = agentJob(id: jobId), job.status == .running, let sessionKey = job.sessionKey else { return }
        let deadline = ContinuousClock.now + Self.agentSubagentTimeout
        // Let the first turn start streaming before polling.
        try? await Task.sleep(for: .seconds(2))
        while sessionStates[resolveCurrentSessionId(sessionKey)]?.isStreaming == true {
            if Task.isCancelled || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard agentJob(id: jobId)?.status == .running else { return }
        if Task.isCancelled || ContinuousClock.now >= deadline {
            await stopAgentThread(sessionKey)
            let reason = Task.isCancelled
                ? String(localized: "The job was cancelled.")
                : String(localized: "The subagent ran longer than the time limit and was stopped.")
            await finishAgentJob(jobId, status: Task.isCancelled ? .cancelled : .failed, summary: nil, error: reason)
            return
        }
        let resolved = resolveCurrentSessionId(sessionKey)
        updateAgentJob(jobId) { $0.sessionKey = resolved }
        let messages = await agentThreadMessages(resolved)
        let lastError = messages.last.flatMap { $0.isError ? $0.content : nil }
        let finalMessage = messages
            .last { $0.role == .assistant && !$0.isError && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .content
        if let lastError {
            await finishAgentJob(jobId, status: .failed, summary: finalMessage, error: lastError)
        } else {
            await finishAgentJob(jobId, status: .succeeded, summary: finalMessage, error: nil)
        }
    }

    /// The thread's messages: live when loaded, else from disk.
    func agentThreadMessages(_ sessionId: String) async -> [ChatMessage] {
        if let messages = sessionStates[sessionId]?.messages, !messages.isEmpty { return messages }
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionId }),
              let project = sessionProject(id: summary.projectId),
              let session = await persistence.loadFullSession(summary: summary, cwd: project.path) else { return [] }
        return cleanLoadedMessages(session.messages)
    }

    func stopAgentThread(_ sessionKey: String) async {
        let sessionId = resolveCurrentSessionId(sessionKey)
        guard sessionStates[sessionId]?.isStreaming == true else { return }
        let window = WindowState()
        window.currentSessionId = sessionId
        if let summary = allSessionSummaries.first(where: { $0.id == sessionId }) {
            window.selectedProject = sessionProject(id: summary.projectId)
        }
        await cancelStreaming(in: window)
        broadcastMobileSessionStatus(sessionID: sessionId)
    }

    // MARK: Background shell tasks

    @discardableResult
    func startBackgroundShellTask(
        agentId: UUID,
        title: String,
        command: String,
        workingDirectory: String?,
        timeout: Duration,
        parentSessionId: String?
    ) async throws -> AgentJob {
        guard let agent = agentProfile(id: agentId) else { throw AgentHubError.unknownAgent }
        try await ensureAgentWorkingDirectory(agent)
        let folder = workingDirectory.map { ($0 as NSString).expandingTildeInPath } ?? agentWorkingDirectory(agent)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IDEToolError.invalidArguments("working_directory does not exist: \(folder)")
        }
        let job = AgentJob(
            agentId: agentId, kind: .shell, title: title, prompt: command, status: .running,
            parentSessionId: parentSessionId.map(resolveCurrentSessionId), workingDirectory: folder, startedAt: .now
        )
        recordAgentJob(job)
        let run = BackgroundShellRun(command: command, workingDirectory: folder, timeout: timeout)
        agentShellRuns[job.id] = run
        agentJobTasks[job.id] = Task { [weak self] in
            let timeoutTask = run.startTimeout()
            let outcome = await run.run()
            timeoutTask.cancel()
            guard let self else { return }
            agentShellRuns.removeValue(forKey: job.id)
            guard agentJob(id: job.id)?.status == .running else { return }
            let status: AgentJob.Status
            let error: String?
            if outcome.cancelled {
                status = .cancelled
                error = String(localized: "The task was cancelled.")
            } else if outcome.timedOut {
                status = .failed
                error = String(localized: "The command ran longer than its time limit and was stopped.")
            } else if outcome.exitCode == 0 {
                status = .succeeded
                error = nil
            } else {
                status = .failed
                error = String(localized: "The command exited with status \(outcome.exitCode).")
            }
            updateAgentJob(job.id) { $0.exitCode = outcome.exitCode }
            await finishAgentJob(job.id, status: status, summary: outcome.output, error: error)
        }
        return job
    }

    /// The live output of a running shell job.
    func agentShellOutput(_ jobId: UUID) -> String? {
        agentShellRuns[jobId]?.currentOutput()
    }

    // MARK: Ending jobs

    /// Records how a job ended and reports it to its agent unless it was
    /// cancelled on purpose.
    func finishAgentJob(_ jobId: UUID, status: AgentJob.Status, summary: String?, error: String?) async {
        guard let current = agentJob(id: jobId), current.status.isActive else { return }
        updateAgentJob(jobId) { $0.finish(status, summary: summary, error: error) }
        agentJobTasks.removeValue(forKey: jobId)
        logger.info("[Agents] job=\(jobId.uuidString, privacy: .public) finished status=\(status.rawValue, privacy: .public)")
        guard status != .cancelled, let finished = agentJob(id: jobId) else {
            updateAgentJob(jobId) { $0.parentNotified = true }
            return
        }
        await reportAgentJob(finished)
    }

    /// Stops a queued or running job. The agent is not told about it.
    func cancelAgentJob(_ jobId: UUID, reason: String? = nil) async {
        guard let job = agentJob(id: jobId), job.status.isActive else { return }
        agentShellRuns[jobId]?.cancel()
        agentJobTasks.removeValue(forKey: jobId)?.cancel()
        if let sessionKey = job.sessionKey { await stopAgentThread(sessionKey) }
        updateAgentJob(jobId) {
            $0.finish(.cancelled, summary: job.resultSummary, error: reason ?? String(localized: "Cancelled."))
            $0.parentNotified = true
        }
    }

    /// Tells the agent how a job ended, in the conversation that started it
    /// (or its latest one), so it can follow up and message the user.
    func reportAgentJob(_ job: AgentJob) async {
        guard !job.parentNotified, let agent = agentProfile(id: job.agentId) else { return }
        let report = job.completionReport
        let display = job.kind == .collaboration
            ? String(localized: "↩︎ \(job.targetAgentName ?? "Teammate") replied to “\(job.displayTitle)” (\(job.status.rawValue))")
            : String(localized: "↩︎ \(job.kind == .shell ? "Background task" : "Subagent") “\(job.displayTitle)” \(job.status.rawValue)")
        let parent = job.parentSessionId.map(resolveCurrentSessionId)
        let target = parent.flatMap { id in allSessionSummaries.first { $0.id == id && $0.projectId == agent.id } }?.id
            ?? agentConversationSummary(agent)?.id
        do {
            if let target {
                let sessionId = resolveCurrentSessionId(target)
                if sessionStates[sessionId]?.isStreaming == true {
                    // Delivered right after the running turn.
                    let queued = QueuedMessage(text: report, attachments: [])
                    threadStore.appendQueued(sessionKey: sessionId, message: queued)
                    appendToWindowQueueMirrors(sessionID: sessionId, message: queued)
                    broadcastMobileSessionStatus(sessionID: sessionId)
                    updateAgentJob(job.id) { $0.parentNotified = true }
                    return
                }
                let result = try await sendCrossProject(
                    projectId: agent.id, threadId: sessionId, prompt: report, displayText: display,
                    waitForResponse: false
                )
                if let error = result.error { throw AgentHubError.sendFailed(error) }
            } else {
                try await sendMessageToAgent(agent.id, text: report, displayText: display)
            }
            updateAgentJob(job.id) { $0.parentNotified = true }
        } catch {
            logger.error("[Agents] could not report job=\(job.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Schedules

    /// Starts one run of an agent's schedule as a subagent. Returns the
    /// subagent's thread, or `nil` when it could not start.
    func launchAgentScheduledRun(_ task: ScheduledTask, agentId: UUID) async -> String? {
        guard agentProfile(id: agentId) != nil else { return nil }
        let job = AgentJob(
            agentId: agentId, kind: .scheduled, title: task.name, prompt: task.runPrompt,
            scheduleId: task.id, agent: task.agent
        )
        recordAgentJob(job)
        guard let launched = await launchSubagentJob(job.id), let sessionKey = launched.sessionKey else { return nil }
        agentJobTasks[job.id] = Task { [weak self] in
            await self?.monitorSubagentJob(job.id)
        }
        return sessionKey
    }
}
