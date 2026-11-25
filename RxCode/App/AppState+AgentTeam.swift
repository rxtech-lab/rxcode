import Foundation
import os
import RxCodeCore

// MARK: - Agents: teammates and agent-to-agent requests

extension AppState {
    /// Whether any thread of the agent (conversation, teammate replies or
    /// subagents) is streaming right now.
    func isAgentBusy(_ agentId: UUID) -> Bool {
        guard let agent = agentProfile(id: agentId) else { return false }
        for (key, state) in sessionStates where state.isStreaming {
            if let owner = agentSessionOwners[key], agent.owns(projectId: owner) { return true }
            if let summary = allSessionSummaries.first(where: { $0.id == key }), agent.owns(projectId: summary.projectId) {
                return true
            }
        }
        return false
    }

    /// What the agent is doing, for its avatar and status line.
    func agentActivity(_ agentId: UUID) -> AgentActivity {
        let jobs = agentJobs.filter { $0.agentId == agentId || $0.targetAgentId == agentId }
        if isAgentBusy(agentId) || jobs.contains(where: { $0.targetAgentId == agentId && $0.status == .running }) {
            return .working
        }
        if jobs.contains(where: { $0.agentId == agentId && $0.status.isActive }) { return .waiting }
        if let latest = jobs.filter({ $0.agentId == agentId }).compactMap({ job in job.finishedAt.map { (job, $0) } })
            .max(by: { $0.1 < $1.1 }), Date.now.timeIntervalSince(latest.1) < 90 {
            return latest.0.status == .succeeded ? .celebrating : (latest.0.status == .failed ? .failed : .idle)
        }
        return .idle
    }

    /// The other agents `agent` can contact, as its prompt describes them.
    func agentTeammates(of agentId: UUID) -> [AgentPromptBuilder.TeammateLine] {
        agentProfiles.filter { $0.id != agentId }.map {
            AgentPromptBuilder.TeammateLine(id: $0.id, name: $0.displayName, summary: $0.roleSummary, isBusy: isAgentBusy($0.id))
        }
    }

    /// Threads in which `agent` answered requests from other agents, newest first.
    func agentCollaborationSummaries(_ agent: AgentProfile) -> [ChatSession.Summary] {
        allSessionSummaries
            .filter { $0.projectId == agent.id && $0.threadLabel == AgentJob.collaborationThreadLabel && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Requests sent between agents, newest first. With `agentId`, only those
    /// the agent sent or received.
    func agentCollaborations(involving agentId: UUID? = nil) -> [AgentJob] {
        agentJobs
            .filter { $0.kind == .collaboration && (agentId == nil || $0.agentId == agentId || $0.targetAgentId == agentId) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Resolves a teammate from an id or a (case-insensitive) name.
    func resolveTeammate(_ reference: String, excluding agentId: UUID) -> AgentProfile? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed) {
            return agentProfiles.first { $0.id == id && $0.id != agentId }
        }
        let others = agentProfiles.filter { $0.id != agentId }
        return others.first { $0.displayName.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? others.first { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    /// The hop count of the request a session answers, or `nil` when the
    /// session is not a teammate reply thread.
    func collaborationHopCount(forSession sessionKey: String) -> Int? {
        let resolved = resolveCurrentSessionId(sessionKey)
        return agentJobs.first { job in
            guard job.kind == .collaboration, let key = job.sessionKey else { return false }
            return key == sessionKey || key == resolved || resolveCurrentSessionId(key) == resolved
        }?.hopCount
    }

    /// Sends a request from one agent to another. The teammate answers as
    /// itself in a new thread of its conversation project, and its final
    /// message is reported back to the requester. Returns at once.
    @discardableResult
    func contactAgent(
        from senderId: UUID,
        to targetId: UUID,
        title: String,
        message: String,
        parentSessionId: String?
    ) throws -> AgentJob {
        guard let sender = agentProfile(id: senderId), let target = agentProfile(id: targetId) else {
            throw AgentHubError.unknownAgent
        }
        guard senderId != targetId else { throw AgentHubError.contactSelf }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentHubError.emptyMessage }
        let hops = parentSessionId.flatMap(collaborationHopCount(forSession:)).map { $0 + 1 } ?? 0
        guard hops < AgentJob.maxCollaborationHops else { throw AgentHubError.collaborationTooDeep }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = AgentJob(
            agentId: senderId, kind: .collaboration,
            title: cleanTitle.isEmpty ? String(text.prefix(60)) : cleanTitle,
            prompt: text,
            parentSessionId: parentSessionId.map(resolveCurrentSessionId),
            targetAgentId: targetId, targetAgentName: target.displayName, hopCount: hops
        )
        agentJobs.insert(job, at: 0)
        agentJobs = AgentJob.pruned(agentJobs)
        persistAgentHub()
        logger.info("[Agents] \(sender.displayName, privacy: .public) → \(target.displayName, privacy: .public) job=\(job.id.uuidString, privacy: .public)")

        agentJobTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            guard await self.launchCollaborationJob(job.id, senderName: sender.displayName) != nil else { return }
            await self.monitorSubagentJob(job.id)
        }
        return job
    }

    /// Opens the teammate's reply thread and sends the request.
    private func launchCollaborationJob(_ jobId: UUID, senderName: String) async -> AgentJob? {
        guard let job = agentJob(id: jobId), job.status == .queued,
              let targetId = job.targetAgentId, let target = agentProfile(id: targetId) else {
            await finishAgentJob(jobId, status: .failed, summary: nil, error: AgentHubError.unknownAgent.localizedDescription)
            return nil
        }
        setAgentJobRunning(jobId)
        let prompt = """
        [Request from teammate] \(senderName) — another agent the user created — asks for your help.
        Title: \(job.displayTitle)

        \(job.prompt)

        Work on it as yourself. Your final message is delivered to \(senderName) as your reply, so end with a clear, \
        self-contained answer. Don't send this request back to \(senderName).
        """
        let config = resolvedAgentConfig(target)
        do {
            try await ensureAgentWorkingDirectory(target)
            let result = try await sendCrossProject(
                projectId: target.id, threadId: nil, prompt: prompt,
                displayText: String(localized: "From \(senderName): \(job.prompt)"),
                agentProvider: config.provider, model: config.model, effort: config.effort,
                permissionMode: config.permissionMode, waitForResponse: false, timeoutSeconds: 60,
                parentThreadId: job.parentSessionId, threadLabel: AgentJob.collaborationThreadLabel
            )
            if let error = result.error {
                await finishAgentJob(jobId, status: .failed, summary: nil, error: error)
                return nil
            }
            registerAgentSession(result.threadId, projectId: target.id)
            setAgentJobSession(jobId, sessionKey: result.threadId)
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

    private func setAgentJobRunning(_ jobId: UUID) {
        guard let index = agentJobs.firstIndex(where: { $0.id == jobId }) else { return }
        agentJobs[index].status = .running
        agentJobs[index].startedAt = .now
        persistAgentHub()
    }

    private func setAgentJobSession(_ jobId: UUID, sessionKey: String) {
        guard let index = agentJobs.firstIndex(where: { $0.id == jobId }) else { return }
        agentJobs[index].sessionKey = sessionKey
        persistAgentHub()
    }
}

/// What an agent is doing, shown by its animated avatar.
enum AgentActivity: Equatable {
    case idle
    /// One of its threads is streaming.
    case working
    /// Waiting on a subagent, background task or teammate.
    case waiting
    /// A job just succeeded.
    case celebrating
    /// A job just failed.
    case failed

    var label: LocalizedStringResource {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Waiting on a job"
        case .celebrating: "Just finished"
        case .failed: "Needs attention"
        }
    }
}
