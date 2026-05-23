import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Project Management

    func addProject(name: String, path: String, gitHubRepo: String?) async {
        guard !projects.contains(where: { $0.path == path }) else { return }
        let project = Project(name: name, path: path, gitHubRepo: gitHubRepo)
        projects.append(project)
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects: \(error.localizedDescription)")
        }
    }

    func selectProject(_ project: Project, in window: WindowState) {
        guard window.selectedProject?.id != project.id else { return }

        saveDraft(in: window)
        saveQueue(in: window)

        if isStreaming(in: window) {
            detachCurrentStream(in: window)
        }

        if let currentId = window.currentSessionId,
           let currentProject = window.selectedProject,
           let state = sessionStates[currentId],
           !state.messages.isEmpty
        {
            let title = allSessionSummaries.first(where: { $0.id == currentId })?.title ?? "Session"
            let provider = state.agentProvider ?? allSessionSummaries.first(where: { $0.id == currentId })?.agentProvider ?? selectedAgentProvider
            let origin = allSessionSummaries.first(where: { $0.id == currentId })?.origin ?? provider.defaultSessionOrigin
            let summary = allSessionSummaries.first(where: { $0.id == currentId })
            let session = ChatSession(
                id: currentId,
                projectId: currentProject.id,
                title: title,
                messages: state.messages,
                updatedAt: lastResponseDate(from: state.messages),
                isPinned: summary?.isPinned ?? false,
                agentProvider: provider,
                model: state.model,
                effort: state.effort,
                permissionMode: state.permissionMode,
                origin: origin,
                worktreePath: summary?.worktreePath,
                worktreeBranch: summary?.worktreeBranch,
                isArchived: summary?.isArchived ?? false,
                archivedAt: summary?.archivedAt
            )
            Task {
                do { try await self.persistence.saveSession(session) }
                catch { self.logger.error("Failed to save current session before project switch: \(error.localizedDescription)") }
            }
        }

        // animation: nil — all mutations land in the same frame; sessionStates.filter fires
        // one @Observable notification instead of N removeValue calls.
        withAnimation(nil) {
            window.showingBriefing = false
            window.selectedProject = project
            sessionStates = sessionStates.filter { $0.value.isStreaming }
            resetToNewChat(in: window)
        }

        activeProjectPath = project.path
        Task { await refreshMCPServers() }
        UserDefaults.standard.set(project.id.uuidString, forKey: "selectedProjectId")
    }

    func addProjectFromFolder(_ url: URL, in window: WindowState) async {
        let isGitRepo = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        let gitHubRepo = isGitRepo ? detectGitHubOwnerRepo(at: url.path) : nil
        await addAndSelectProject(name: url.lastPathComponent, path: url.path, gitHubRepo: gitHubRepo, in: window)
    }

    func addAndSelectProject(name: String, path: String, gitHubRepo: String? = nil, in window: WindowState) async {
        if let existing = projects.first(where: { $0.path == path }) {
            selectProject(existing, in: window)
            return
        }
        await addProject(name: name, path: path, gitHubRepo: gitHubRepo)
        if let project = projects.last {
            selectProject(project, in: window)
        }
    }

    // MARK: - Session Management

    func switchToSession(_ session: ChatSession, messages loadedMessages: [ChatMessage]? = nil, in window: WindowState) {
        let existingState = sessionStates[session.id]
        logger.info("[SwitchToSession] sid=\(session.id, privacy: .public) hasState=\(existingState != nil) existingMessages=\(existingState?.messages.count ?? -1) existingIsStreaming=\(existingState?.isStreaming ?? false) preloadedMessages=\(loadedMessages?.count ?? -1)")
        saveDraft(in: window)
        saveQueue(in: window)

        if isStreaming(in: window) {
            detachCurrentStream(in: window)
        }

        let outgoingId = window.currentSessionId

        if sessionStates[session.id] == nil {
            var state = SessionStreamState()
            state.agentProvider = session.agentProvider
            state.model = session.model
            state.effort = session.effort
            state.permissionMode = session.permissionMode
            if let msgs = loadedMessages {
                state.messages = cleanLoadedMessages(msgs)
                state.planDecisionSummaries = threadStore.loadPlanDecisions(sessionId: session.id)
                sessionStates[session.id] = state
                logger.info("[SwitchToSession] applied preloaded messages sid=\(session.id, privacy: .public) cleaned=\(state.messages.count)")
            } else {
                // Switch with an empty state first; actual messages are loaded in the background and injected later
                state.isLoadingFromDisk = true
                sessionStates[session.id] = state
                if let project = window.selectedProject {
                    logger.info("[SwitchToSession] background load triggered sid=\(session.id, privacy: .public) cwd=\(project.path, privacy: .public)")
                    loadMessagesInBackground(projectId: project.id, sessionId: session.id, cwd: project.path)
                } else {
                    logger.error("[SwitchToSession] no selectedProject — cannot load messages sid=\(session.id, privacy: .public)")
                }
            }
        } else if sessionStates[session.id]?.messages.isEmpty == true,
                  sessionStates[session.id]?.isStreaming != true,
                  let project = window.selectedProject
        {
            if var state = sessionStates[session.id] {
                if state.model == nil { state.model = session.model }
                if state.agentProvider == nil { state.agentProvider = session.agentProvider }
                if state.effort == nil { state.effort = session.effort }
                if state.permissionMode == nil { state.permissionMode = session.permissionMode }
                state.isLoadingFromDisk = true
                sessionStates[session.id] = state
            }
            logger.info("[SwitchToSession] re-loading empty cached state sid=\(session.id, privacy: .public) cwd=\(project.path, privacy: .public)")
            loadMessagesInBackground(projectId: project.id, sessionId: session.id, cwd: project.path)
        } else {
            logger.info("[SwitchToSession] reusing cached state sid=\(session.id, privacy: .public) messages=\(existingState?.messages.count ?? -1) isStreaming=\(existingState?.isStreaming ?? false)")
        }

        if sessionStates[session.id]?.isStreaming == true {
            flushPendingUpdates(for: session.id, forceText: true)
        }

        updateState(session.id) { $0.hasUncheckedCompletion = false }

        window.showingBriefing = false
        window.pendingWorktreePath = nil
        window.pendingWorktreeBranch = nil
        window.currentSessionId = session.id
        window.sessionAgentProvider = sessionStates[session.id]?.agentProvider ?? session.agentProvider
        window.sessionModel = sessionStates[session.id]?.model ?? session.model
        window.sessionEffort = sessionStates[session.id]?.effort ?? session.effort
        window.sessionPermissionMode = sessionStates[session.id]?.permissionMode ?? session.permissionMode
        window.sessionPlanMode = sessionStates[session.id]?.planMode ?? false
        window.inputText = window.draftTexts[session.id] ?? ""
        window.messageQueue = window.draftQueues[session.id] ?? []

        releaseOutgoingSession(outgoingId, excluding: session.id, in: window)

        if sessionStates[session.id]?.isStreaming == true {
            startFlushTimer(for: session.id)
        }
    }

    func releaseOutgoingSession(_ outgoingId: String?, excluding newId: String? = nil, in window: WindowState) {
        guard let outgoingId,
              outgoingId != newId,
              !(sessionStates[outgoingId]?.isStreaming ?? false) else { return }
        let outgoingMessages = sessionStates[outgoingId]?.messages ?? []
        Task { [weak self] in
            guard let self else { return }
            if !outgoingMessages.isEmpty, let project = window.selectedProject {
                let summary = allSessionSummaries.first(where: { $0.id == outgoingId })
                let title = summary?.title ?? "Session"
                let state = sessionStates[outgoingId]
                let provider = state?.agentProvider ?? summary?.agentProvider ?? selectedAgentProvider
                let origin = summary?.origin ?? provider.defaultSessionOrigin
                let outgoing = ChatSession(
                    id: outgoingId,
                    projectId: project.id,
                    title: title,
                    messages: outgoingMessages,
                    updatedAt: lastResponseDate(from: outgoingMessages),
                    isPinned: summary?.isPinned ?? false,
                    agentProvider: provider,
                    model: state?.model,
                    effort: state?.effort,
                    permissionMode: state?.permissionMode,
                    origin: origin,
                    worktreePath: summary?.worktreePath,
                    worktreeBranch: summary?.worktreeBranch,
                    isArchived: summary?.isArchived ?? false,
                    archivedAt: summary?.archivedAt
                )
                do { try await persistence.saveSession(outgoing) }
                catch { logger.error("Failed to save outgoing session: \(error.localizedDescription)") }
            }
            if window.currentSessionId != outgoingId {
                sessionStates.removeValue(forKey: outgoingId)
            }
        }
    }

    func didSwitchToSession(_ session: ChatSession) async {
        if let index = projects.firstIndex(where: { $0.id == session.projectId }) {
            projects[index].lastSessionId = session.id
            do {
                try await persistence.saveProjects(projects)
            } catch {
                logger.error("Failed to save projects: \(error.localizedDescription)")
            }
        }
    }

    func resumeSession(_ session: ChatSession, in window: WindowState) async {
        switchToSession(session, in: window)
        await didSwitchToSession(session)
    }

    // MARK: - GitHub

    func loginToGitHub() async throws -> DeviceCodeResponse {
        try await github.startDeviceFlow()
    }

    func completeGitHubLogin(deviceCode: String, interval: Int) async throws {
        _ = try await github.pollForToken(deviceCode: deviceCode, interval: interval)

        let user = try await github.fetchUser()
        gitHubUser = user
        isLoggedIn = true
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")

        do { try await persistence.saveGitHubUser(user) }
        catch { logger.error("Failed to cache GitHub user: \(error.localizedDescription)") }

        do {
            let publicKey = try await github.setupSSH()
            try await github.registerSSHKey(publicKey)
        } catch {
            logger.warning("SSH setup failed: \(error.localizedDescription)")
        }
    }

    func skipGitHubLogin() {
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
    }


    func fetchRepos() async {
        isFetchingRepos = true
        defer { isFetchingRepos = false }
        do { repos = try await github.fetchRepos() }
        catch { logger.error("Failed to fetch repos: \(error.localizedDescription)") }
    }

    func cloneAndAddProject(_ repo: GitHubRepo, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(repo.name)"
        let parentDir = "\(home)/RxCode"
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        try await github.cloneRepo(repo, to: clonePath)
        await addAndSelectProject(name: repo.name, path: clonePath, gitHubRepo: repo.fullName, in: window)
    }

    func loadCustomRepos() async {
        customRepos = await persistence.loadCustomRepos()
    }

    func addCustomRepo(url: String, name: String, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(name)"
        let fm = FileManager.default
        if !fm.fileExists(atPath: "\(home)/RxCode") {
            try fm.createDirectory(atPath: "\(home)/RxCode", withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: clonePath) {
            throw NSError(domain: "RxCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(name)' already exists in ~/RxCode"])
        }
        try await github.cloneRepo(from: url, to: clonePath)
        let repo = CustomRepo(name: name, cloneURL: url)
        customRepos.append(repo)
        try await persistence.saveCustomRepos(customRepos)
        await addAndSelectProject(name: name, path: clonePath, gitHubRepo: nil, in: window)
    }

    func cloneCustomRepo(_ repo: CustomRepo, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(repo.name)"
        let fm = FileManager.default
        if !fm.fileExists(atPath: "\(home)/RxCode") {
            try fm.createDirectory(atPath: "\(home)/RxCode", withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: clonePath) {
            throw NSError(domain: "RxCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(repo.name)' already exists in ~/RxCode"])
        }
        try await github.cloneRepo(from: repo.cloneURL, to: clonePath)
        await addAndSelectProject(name: repo.name, path: clonePath, gitHubRepo: nil, in: window)
    }

    func removeCustomRepo(_ repo: CustomRepo) async {
        customRepos.removeAll { $0.id == repo.id }
        do {
            try await persistence.saveCustomRepos(customRepos)
        } catch {
            logger.error("Failed to save custom repos: \(error.localizedDescription)")
        }
    }

}
