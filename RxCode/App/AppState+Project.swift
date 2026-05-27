import AppKit
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

        AnalyticsService.shared.log(.projectOpened, parameters: [
            "project_id": project.id.uuidString,
        ])

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

    // MARK: - rxauth + autopilot

    /// Called from `RxAuthSignInView.onAuthSuccess` once `OAuthManager` has
    /// switched to `.authenticated`. `isSignedIn`/`rxUser` track the manager
    /// directly; this hook only handles the side effects (mark onboarding
    /// complete, kick off a background repo fetch).
    func onRxAuthSignedIn() {
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        Task { await loadRepos() }
    }

    func signOutRxAuth() async {
        await rxAuth.signOut()
        repos = []
        installations = []
        hasGitHubAppInstalled = nil
        repoNextCursor = nil
        repoHasMoreRepos = false
        repoCurrentSearch = ""
    }

    /// Default page size for the server-side paginated repo list.
    static let defaultRepoPageSize = 50

    /// Load the first page for the given search term, plus the parallel
    /// installation list used to render owner avatars in the import-repo
    /// sheet. Replaces any previously loaded repos. Pass `refresh: true` to
    /// bust the server's 60s cache on the repos endpoint (installations
    /// always refetch).
    func loadRepos(search: String = "", refresh: Bool = false) async {
        guard isSignedIn else { return }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        repoCurrentSearch = trimmed
        let requestedSearch = trimmed
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        async let reposTask = autopilot.listRepositories(
            search: trimmed.isEmpty ? nil : trimmed,
            cursor: nil,
            perPage: AppState.defaultRepoPageSize,
            refresh: refresh
        )
        async let installationsTask = autopilot.listInstallations()
        do {
            let response = try await reposTask
            // A newer search may have replaced `repoCurrentSearch` while this
            // request was in flight — drop the stale result so the UI doesn't
            // briefly show repos for the previous query.
            guard requestedSearch == repoCurrentSearch else { return }
            repos = response.items
            repoNextCursor = response.pagination?.nextCursor
            repoHasMoreRepos = response.pagination?.hasMore ?? false
        } catch {
            logger.error("Failed to fetch repos from autopilot: \(error.localizedDescription)")
        }
        do {
            installations = try await installationsTask
        } catch {
            // Avatars degrade gracefully — log and continue with the existing
            // list rather than failing the whole load.
            logger.error("Failed to fetch installations from autopilot: \(error.localizedDescription)")
        }
    }

    /// Fetch the next page for the currently displayed search term. No-op when
    /// the server reported no more pages, a load is already in flight, or the
    /// user is signed out.
    func loadMoreRepos() async {
        guard isSignedIn, !isLoadingRepos, !isLoadingMoreRepos else { return }
        guard repoHasMoreRepos, let cursor = repoNextCursor else { return }
        let requestedSearch = repoCurrentSearch
        isLoadingMoreRepos = true
        defer { isLoadingMoreRepos = false }
        do {
            let response = try await autopilot.listRepositories(
                search: requestedSearch.isEmpty ? nil : requestedSearch,
                cursor: cursor,
                perPage: AppState.defaultRepoPageSize
            )
            // Drop the page if the search changed while we were loading.
            guard requestedSearch == repoCurrentSearch else { return }
            // Defensive: server returns deduped pages, but if the user kicked
            // a refresh between pages we could see overlap — dedupe by id.
            let existingIds = Set(repos.map(\.id))
            repos.append(contentsOf: response.items.filter { !existingIds.contains($0.id) })
            repoNextCursor = response.pagination?.nextCursor
            repoHasMoreRepos = response.pagination?.hasMore ?? false
        } catch {
            logger.error("Failed to fetch next repo page from autopilot: \(error.localizedDescription)")
        }
    }

    /// Tiny "do you have any installations?" probe. Stored on AppState so
    /// the sheet can branch on it without holding its own state machine.
    func checkInstallation() async {
        guard isSignedIn else {
            hasGitHubAppInstalled = nil
            return
        }
        isCheckingInstall = true
        defer { isCheckingInstall = false }
        do {
            let result = try await autopilot.precheckInstallations()
            hasGitHubAppInstalled = result.hasInstallation
        } catch {
            logger.error("Failed to precheck installations: \(error.localizedDescription)")
        }
    }

    /// Fetch a fresh GitHub App install URL (with signed state) and open it
    /// in the user's default browser. The sheet's Refresh button is then
    /// responsible for picking up the resulting installation.
    func openInstallGitHubApp() async {
        guard isSignedIn else { return }
        isOpeningInstallUrl = true
        defer { isOpeningInstallUrl = false }
        do {
            let response = try await autopilot.installUrl()
            guard let url = URL(string: response.url) else {
                logger.error("autopilot returned an invalid install URL: \(response.url)")
                return
            }
            NSWorkspace.shared.open(url)
        } catch {
            logger.error("Failed to fetch install URL: \(error.localizedDescription)")
        }
    }

    /// User-triggered "did the install land?" refresh. Re-runs the precheck
    /// and, if installed, follows up with a forced repo refresh so the new
    /// installation's repos show up immediately.
    func refreshInstallationAndRepos() async {
        await checkInstallation()
        if hasGitHubAppInstalled == true {
            await loadRepos(search: repoCurrentSearch, refresh: true)
        } else {
            repos = []
            repoNextCursor = nil
            repoHasMoreRepos = false
        }
    }

    func cloneAndAddProject(_ repo: AutopilotRepo, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(repo.name)"
        let parentDir = "\(home)/RxCode"
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        let cloneURL = repo.isPrivate ? repo.sshUrl : repo.cloneUrl
        try await gitClone(from: cloneURL, to: clonePath)
        await addAndSelectProject(name: repo.name, path: clonePath, gitHubRepo: repo.fullName, in: window)
    }

    private func gitClone(from url: String, to path: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", url, path]
        process.environment = ProcessInfo.processInfo.environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "RxCode.GitClone", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
    }
}
