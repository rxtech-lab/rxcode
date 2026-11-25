import Foundation
import os
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Agents: storage, projects and conversations

extension AppState {
    /// The workspace's agent store, created on first use.
    var agentHubStore: AgentHubStore {
        if let store = agentHubStoreInstance { return store }
        let store = AgentHubStore(rootURL: activeWorkspace.storageURL.appendingPathComponent("agents", isDirectory: true))
        agentHubStoreInstance = store
        return store
    }

    func loadAgentHubFromDisk() async {
        let contents = await agentHubStore.load()
        agentProfiles = contents.agents
        agentMemoryNotes = contents.memory
        agentJobs = contents.jobs
        agentRemoteAccess = contents.remoteAccess
        agentHubLoaded = true
        screenShareService.apply(agentRemoteAccess)
        // Jobs cut off by the last quit are already marked; nothing else to resume.
        scheduleAgentHubBroadcast()
    }

    /// Saves everything after a short delay so bursts of edits write once,
    /// and tells paired phones.
    func persistAgentHub() {
        guard agentHubLoaded else { return }
        agentHubPersistenceTask?.cancel()
        agentHubPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let contents = AgentHubStore.Contents(
                agents: agentProfiles, memory: agentMemoryNotes, jobs: agentJobs, remoteAccess: agentRemoteAccess
            )
            await agentHubStore.save(contents)
        }
        scheduleAgentHubBroadcast()
    }

    // MARK: Lookup

    func agentProfile(id: UUID) -> AgentProfile? {
        agentProfiles.first { $0.id == id }
    }

    /// The agent whose conversation or subagent project is `projectId`.
    func agentOwning(projectId: UUID) -> (agent: AgentProfile, role: AgentPromptBuilder.Role)? {
        for agent in agentProfiles {
            if agent.id == projectId { return (agent, .conversation) }
            if agent.subagentProjectId == projectId { return (agent, .subagent) }
        }
        return nil
    }

    func isAgentProject(_ projectId: UUID) -> Bool {
        agentOwning(projectId: projectId) != nil
    }

    /// The route a chat in `project` belongs on.
    func chatRoute(for project: Project?) -> GeneralRoute? {
        guard let project else { return nil }
        if project.isGlobalChat { return .chat }
        if isAgentProject(project.id) { return .agents }
        return nil
    }

    /// Folder the agent's turns and shell tasks run in.
    func agentWorkingDirectory(_ agent: AgentProfile) -> String {
        if let path = agent.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return (path as NSString).expandingTildeInPath
        }
        return agentHubStore.homeURL(for: agent.id).path
    }

    func agentConversationProject(_ agent: AgentProfile) -> Project {
        Project(id: agent.id, name: agent.displayName, path: agentWorkingDirectory(agent))
    }

    func agentSubagentProject(_ agent: AgentProfile) -> Project {
        Project(
            id: agent.subagentProjectId,
            name: String(localized: "\(agent.displayName) · Subagents"),
            path: agentWorkingDirectory(agent)
        )
    }

    /// The conversation or subagent project with `id`, if an agent owns it.
    func agentVirtualProject(id: UUID) -> Project? {
        guard let owner = agentOwning(projectId: id) else { return nil }
        return owner.role == .conversation ? agentConversationProject(owner.agent) : agentSubagentProject(owner.agent)
    }

    var agentVirtualProjects: [Project] {
        agentProfiles.flatMap { [agentConversationProject($0), agentSubagentProject($0)] }
    }

    /// The model every turn of `agent` uses: its own, else the default task agent.
    func resolvedAgentConfig(_ agent: AgentProfile) -> TaskAgentConfig {
        agent.agent.isAssigned ? agent.agent : defaultTaskAgent()
    }

    // MARK: Conversations

    /// The agent's conversation threads, newest first.
    func agentConversationSummaries(_ agent: AgentProfile) -> [ChatSession.Summary] {
        allSessionSummaries
            .filter {
                $0.projectId == agent.id && !$0.isArchived && $0.threadLabel != AgentJob.collaborationThreadLabel
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The agent's one ongoing conversation, which the Agents tab, the phone,
    /// job reports and teammates all continue: the most recent thread. Agents
    /// made before conversations became continuous may have older threads too.
    func agentConversationSummary(_ agent: AgentProfile) -> ChatSession.Summary? {
        agentConversationSummaries(agent).first
    }

    /// Threads from before the conversation became continuous, newest first.
    func agentEarlierConversations(_ agent: AgentProfile) -> [ChatSession.Summary] {
        Array(agentConversationSummaries(agent).dropFirst())
    }

    /// Threads of the agent's subagents and scheduled runs, newest first.
    func agentSubagentSummaries(_ agent: AgentProfile) -> [ChatSession.Summary] {
        allSessionSummaries
            .filter { $0.projectId == agent.subagentProjectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Shows the agent's ongoing conversation in `window`, or an empty
    /// composer set to the agent's model before the first message.
    func openAgentConversation(_ agentId: UUID, in window: WindowState) {
        guard let agent = agentProfile(id: agentId) else { return }
        let project = agentConversationProject(agent)
        if window.selectedProject?.id != project.id {
            window.cancelSessionSwitchTask()
            selectProject(project, in: window)
        }
        window.generalRoute = .agents
        if let summary = agentConversationSummary(agent) {
            if window.currentSessionId != summary.id {
                selectSession(id: summary.id, in: window)
            }
            if agent.primarySessionId != summary.id, let index = agentProfiles.firstIndex(where: { $0.id == agentId }) {
                agentProfiles[index].primarySessionId = summary.id
                persistAgentHub()
            }
        } else {
            // A teammate reply thread may be showing; the conversation starts fresh.
            if window.currentSessionId != nil { beginNewChat(in: window) }
            applyAgentModel(agent, to: window)
        }
        window.generalRoute = .agents
        window.requestInputFocus = true
    }

    /// Opens one of the agent's threads (conversation or subagent) in `window`.
    func openAgentThread(_ sessionId: String, in window: WindowState) {
        selectSession(id: sessionId, in: window)
        window.generalRoute = .agents
    }

    /// Points a new chat's model controls at the agent's configuration.
    func applyAgentModel(_ agent: AgentProfile, to window: WindowState) {
        let config = resolvedAgentConfig(agent)
        if let model = config.model, !model.isEmpty {
            setSessionModel(model, provider: config.provider, in: window)
        } else if let provider = config.provider {
            window.sessionAgentProvider = provider
        }
        if let effort = config.effort, !effort.isEmpty { window.sessionEffort = effort }
        if let mode = config.permissionMode { setSessionPermissionMode(mode, in: window) }
    }

    /// Sends `text` to the agent's ongoing conversation: queued behind a
    /// running turn, otherwise sent now, starting the conversation when there
    /// is none yet. Returns the thread id.
    @discardableResult
    func sendMessageToAgent(
        _ agentId: UUID,
        text: String,
        displayText: String? = nil
    ) async throws -> String {
        guard let agent = agentProfile(id: agentId) else { throw AgentHubError.unknownAgent }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgentHubError.emptyMessage }
        try await ensureAgentWorkingDirectory(agent)

        if let summary = agentConversationSummary(agent) {
            let sessionId = resolveCurrentSessionId(summary.id)
            if sessionStates[sessionId]?.isStreaming == true {
                let queued = QueuedMessage(text: prompt, attachments: [])
                threadStore.appendQueued(sessionKey: sessionId, message: queued)
                appendToWindowQueueMirrors(sessionID: sessionId, message: queued)
                broadcastMobileSessionStatus(sessionID: sessionId)
                return sessionId
            }
            let result = try await sendCrossProject(
                projectId: agent.id, threadId: sessionId, prompt: prompt,
                displayText: displayText ?? prompt, waitForResponse: false
            )
            if let error = result.error { throw AgentHubError.sendFailed(error) }
            return result.threadId
        }

        let config = resolvedAgentConfig(agent)
        let result = try await sendCrossProject(
            projectId: agent.id, threadId: nil, prompt: prompt, displayText: displayText ?? prompt,
            agentProvider: config.provider, model: config.model, effort: config.effort,
            permissionMode: config.permissionMode, waitForResponse: false
        )
        if let error = result.error { throw AgentHubError.sendFailed(error) }
        if let index = agentProfiles.firstIndex(where: { $0.id == agentId }) {
            agentProfiles[index].primarySessionId = result.threadId
            persistAgentHub()
        }
        return result.threadId
    }

    func ensureAgentWorkingDirectory(_ agent: AgentProfile) async throws {
        let path = agentWorkingDirectory(agent)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }.value
    }

    // MARK: CRUD

    /// Adds `agent`, or replaces the stored agent with the same id.
    @discardableResult
    func upsertAgent(_ agent: AgentProfile) -> AgentProfile {
        var agent = agent
        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.updatedAt = .now
        if let index = agentProfiles.firstIndex(where: { $0.id == agent.id }) {
            let modelChanged = agentProfiles[index].agent != agent.agent
            // The conversation link is owned by the Mac, not by edits from a form.
            agent.phoneMessages = agentProfiles[index].phoneMessages
            agent.primarySessionId = agentProfiles[index].primarySessionId
            agent.subagentProjectId = agentProfiles[index].subagentProjectId
            agent.createdAt = agentProfiles[index].createdAt
            agentProfiles[index] = agent
            if modelChanged { applyAgentModelToConversation(agent) }
        } else {
            agentProfiles.append(agent)
        }
        persistAgentHub()
        return agent
    }

    /// Moves the ongoing conversation onto the agent's (new) model, so an edit
    /// takes effect on the next message instead of only in new threads. A
    /// provider change starts a fresh model session, which gets the recent
    /// messages replayed (see `agentContinuity`).
    func applyAgentModelToConversation(_ agent: AgentProfile) {
        guard let summary = agentConversationSummary(agent) else { return }
        let sessionId = resolveCurrentSessionId(summary.id)
        let config = resolvedAgentConfig(agent)
        guard let provider = config.provider else { return }
        let model = config.model ?? fallbackModel(for: provider, project: agentConversationProject(agent))
        let acpClientId = provider == .acp ? acpSelectionParts(for: model)?.clientId : nil
        updateState(sessionId) { state in
            state.agentProvider = provider
            state.model = model
            if let effort = config.effort { state.setEffort(effort) }
            state.acpClientId = acpClientId
            state.activeModelName = nil
        }
        for window in registeredWindows() where window.currentSessionId == sessionId {
            window.sessionAgentProvider = provider
            window.sessionModel = model
            if let effort = config.effort { window.sessionEffort = effort }
        }
    }

    /// Deletes the agent with its memory, schedules and job history. Its
    /// threads stay in history and search, like those of a removed project.
    func deleteAgent(id: UUID) async {
        guard agentProfile(id: id) != nil else { return }
        for job in agentJobs where (job.agentId == id || job.targetAgentId == id) && job.status.isActive {
            await cancelAgentJob(job.id, reason: "The agent was deleted.")
        }
        for task in scheduledTasks where task.agentId == id {
            deleteScheduledTask(id: task.id)
        }
        agentProfiles.removeAll { $0.id == id }
        agentMemoryNotes.removeAll { $0.agentId == id }
        agentJobs.removeAll { $0.agentId == id }
        agentComputerUseActivity.removeValue(forKey: id)
        persistAgentHub()
        await agentHubStore.removeFolder(for: id)
    }

    func agentSchedules(_ agentId: UUID) -> [ScheduledTask] {
        scheduledTasks.filter { $0.agentId == agentId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Memory

    func agentMemory(_ agentId: UUID) -> [AgentMemoryNote] {
        agentMemoryNotes.filter { $0.agentId == agentId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func addAgentMemory(
        agentId: UUID,
        content: String,
        kind: AgentMemoryNote.Kind,
        source: AgentMemoryNote.Source
    ) throws -> AgentMemoryNote {
        guard agentProfile(id: agentId) != nil else { throw AgentHubError.unknownAgent }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentHubError.emptyMemory }
        let note = AgentMemoryNote(agentId: agentId, content: text, kind: kind, source: source)
        agentMemoryNotes.insert(note, at: 0)
        agentMemoryNotes = AgentMemoryNote.pruned(agentMemoryNotes)
        persistAgentHub()
        return note
    }

    @discardableResult
    func updateAgentMemory(id: UUID, content: String, kind: AgentMemoryNote.Kind?) throws -> AgentMemoryNote {
        guard let index = agentMemoryNotes.firstIndex(where: { $0.id == id }) else { throw AgentHubError.unknownMemory }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentHubError.emptyMemory }
        agentMemoryNotes[index].content = String(text.prefix(AgentMemoryNote.contentLimit))
        if let kind { agentMemoryNotes[index].kind = kind }
        agentMemoryNotes[index].updatedAt = .now
        persistAgentHub()
        return agentMemoryNotes[index]
    }

    func deleteAgentMemory(id: UUID) {
        agentMemoryNotes.removeAll { $0.id == id }
        persistAgentHub()
    }

    // MARK: Remote access

    func setAgentRemoteAccess(_ policy: AgentRemoteAccessPolicy) {
        agentRemoteAccess = AgentRemoteAccessPolicy(allowsViewing: policy.allowsViewing, allowsControl: policy.allowsControl)
        persistAgentHub()
        screenShareService.apply(agentRemoteAccess)
    }

    // MARK: Turn context

    /// Remembers which agent project a session key belongs to, so IDE tool
    /// calls of a brand-new thread resolve before its summary exists.
    func registerAgentSession(_ sessionKey: String, projectId: UUID) {
        guard isAgentProject(projectId) else { return }
        agentSessionOwners[sessionKey] = projectId
    }

    /// The agent and role of the thread behind `sessionKey`.
    func agentContext(forSession sessionKey: String) -> (agent: AgentProfile, role: AgentPromptBuilder.Role)? {
        let resolved = resolveCurrentSessionId(sessionKey)
        if let projectId = agentSessionOwners[sessionKey] ?? agentSessionOwners[resolved],
           let owner = agentOwning(projectId: projectId) {
            return owner
        }
        if let summary = allSessionSummaries.first(where: { $0.id == resolved || $0.id == sessionKey }) {
            return agentOwning(projectId: summary.projectId)
        }
        return nil
    }

    /// The provider and model a session runs with, for computer-use routing.
    func agentSessionModel(_ sessionKey: String, agent: AgentProfile) -> (provider: AgentProvider?, model: String?) {
        let resolved = resolveCurrentSessionId(sessionKey)
        let state = sessionStates[resolved] ?? sessionStates[sessionKey]
        let config = resolvedAgentConfig(agent)
        return (state?.agentProvider ?? config.provider, state?.model ?? config.model)
    }

    /// Background context for one turn in an agent project; empty otherwise.
    func agentPromptContext(
        projectId: UUID,
        sessionKey: String,
        provider: AgentProvider,
        model: String?,
        hasIDETools: Bool,
        resumesNativeSession: Bool = true
    ) -> String {
        guard let owner = agentOwning(projectId: projectId) else { return "" }
        registerAgentSession(sessionKey, projectId: projectId)
        let agent = owner.agent
        let schedules = agentSchedules(agent.id).map {
            AgentPromptBuilder.ScheduleLine(
                id: $0.id, name: $0.name,
                schedule: $0.dueAt.map { "once at \(ISO8601DateFormatter().string(from: $0))" } ?? "cron \($0.cronExpression)",
                isEnabled: $0.isEnabled, nextRun: $0.nextRunDate()
            )
        }
        return AgentPromptBuilder.context(
            agent: agent,
            role: owner.role,
            memory: agentMemory(agent.id),
            jobs: agentJobs.filter { $0.agentId == agent.id },
            schedules: schedules,
            teammates: agentTeammates(of: agent.id),
            continuity: owner.role == .conversation
                ? agentContinuity(sessionKey: sessionKey, resumesNativeSession: resumesNativeSession)
                : nil,
            provider: provider,
            model: model,
            hasIDETools: hasIDETools,
            hasPairedPhone: !MobileSyncService.shared.pairedDevices.isEmpty
        )
    }

    /// When the user last wrote in the thread and, for a turn that starts a
    /// fresh model session on an existing thread, the recent messages to
    /// replay. `nil` for teammate reply threads, which aren't the user's chat.
    func agentContinuity(sessionKey: String, resumesNativeSession: Bool) -> AgentPromptBuilder.Continuity? {
        let resolved = resolveCurrentSessionId(sessionKey)
        if allSessionSummaries.first(where: { $0.id == resolved || $0.id == sessionKey })?.threadLabel
            == AgentJob.collaborationThreadLabel {
            return nil
        }
        var messages = (sessionStates[resolved] ?? sessionStates[sessionKey])?.messages ?? []
        // This turn's own prompt is already in the transcript.
        if messages.last?.role == .user { messages.removeLast() }
        let previousUserMessageAt = messages.last { $0.role == .user }?.timestamp
        guard !resumesNativeSession else {
            return AgentPromptBuilder.Continuity(previousUserMessageAt: previousUserMessageAt, recap: [])
        }
        let recap = messages.suffix(120).compactMap { message -> AgentPromptBuilder.Continuity.Line? in
            guard !message.isError else { return nil }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .init(fromUser: message.role == .user, text: text, timestamp: message.timestamp)
        }
        return AgentPromptBuilder.Continuity(previousUserMessageAt: previousUserMessageAt, recap: recap)
    }

    /// IDE tools an agent thread gets on top of the standard set.
    func agentHubTools(forSession sessionKey: String) -> [IDETool] {
        guard let owner = agentContext(forSession: sessionKey) else { return [] }
        let session = agentSessionModel(sessionKey, agent: owner.agent)
        return IDEToolRegistry.agentHubTools(
            isConversation: owner.role == .conversation,
            notifiesPhone: owner.agent.notifiesPhone,
            computerUse: owner.agent.computerUse.resolvedDriver(provider: session.provider, model: session.model),
            hasTeammates: agentProfiles.count > 1
        )
    }

    // MARK: Phone

    /// Pushes `message` to every paired phone, opening the agent's
    /// conversation when tapped.
    func notifyPhone(fromAgent agent: AgentProfile, title: String?, message: String, sessionId: String?) {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadTitle = (trimmedTitle?.isEmpty == false ? trimmedTitle : nil) ?? agent.displayName
        let body = String(message.prefix(600))
        if let index = agentProfiles.firstIndex(where: { $0.id == agent.id }) {
            let notice = AgentProfile.PhoneMessage(body: body, sessionID: sessionId.map(resolveCurrentSessionId))
            agentProfiles[index].phoneMessages.insert(notice, at: 0)
            agentProfiles[index].phoneMessages = Array(agentProfiles[index].phoneMessages.prefix(50))
            persistAgentHub()
        }
        MobileSyncService.shared.broadcastNotification(NotificationPayload(
            kind: .generic,
            title: String(payloadTitle.prefix(120)),
            body: body,
            sessionID: sessionId.map(resolveCurrentSessionId),
            projectID: agent.id
        ))
    }
}

enum AgentHubError: LocalizedError {
    case unknownAgent
    case unknownMemory
    case unknownJob
    case unknownSchedule
    case emptyMessage
    case emptyMemory
    case contactSelf
    case collaborationTooDeep
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownAgent: String(localized: "This agent no longer exists.")
        case .unknownMemory: String(localized: "This memory note no longer exists.")
        case .unknownJob: String(localized: "This job no longer exists.")
        case .unknownSchedule: String(localized: "This schedule no longer exists.")
        case .emptyMessage: String(localized: "Write a message first.")
        case .emptyMemory: String(localized: "A memory note can't be empty.")
        case .contactSelf: String(localized: "An agent can't send a request to itself.")
        case .collaborationTooDeep:
            String(localized: "This request is already \(AgentJob.maxCollaborationHops) hops deep between agents. Answer it yourself instead of passing it on.")
        case .sendFailed(let message): message
        }
    }
}
