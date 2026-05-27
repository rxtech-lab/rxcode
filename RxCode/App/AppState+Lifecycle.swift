import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Private State

    // MARK: - Window-Scoped Session State Accessors

    func streamState(in window: WindowState) -> SessionStreamState {
        sessionStates[window.currentSessionId ?? window.newSessionKey] ?? SessionStreamState()
    }

    func messages(in window: WindowState) -> [ChatMessage] {
        streamState(in: window).messages
    }

    /// File edits accumulated across this thread, sourced from SwiftData.
    /// Returns an empty array for a not-yet-persisted (placeholder) session.
    func threadFileEdits(in window: WindowState) -> [FileEditSummary] {
        let key = window.currentSessionId ?? window.newSessionKey
        return threadStore.fetchFileEdits(sessionId: key).map { $0.toSummary() }
    }

    func isStreaming(in window: WindowState) -> Bool {
        streamState(in: window).isStreaming
    }

    func isThinking(in window: WindowState) -> Bool {
        streamState(in: window).isThinking
    }

    func streamingStartDate(in window: WindowState) -> Date? {
        streamState(in: window).streamingStartDate
    }

    func activeModelName(in window: WindowState) -> String? {
        streamState(in: window).activeModelName
    }

    func lastTurnContextUsedPercentage(in window: WindowState) -> Double? {
        streamState(in: window).lastTurnContextUsedPercentage
    }

    func sessionCostUsd(in window: WindowState) -> Double {
        streamState(in: window).costUsd
    }

    func sessionTurns(in window: WindowState) -> Int {
        streamState(in: window).turns
    }

    func sessionInputTokens(in window: WindowState) -> Int {
        streamState(in: window).inputTokens
    }

    func sessionOutputTokens(in window: WindowState) -> Int {
        streamState(in: window).outputTokens
    }

    func sessionCacheCreationTokens(in window: WindowState) -> Int {
        streamState(in: window).cacheCreationTokens
    }

    func sessionCacheReadTokens(in window: WindowState) -> Int {
        streamState(in: window).cacheReadTokens
    }

    func sessionDurationMs(in window: WindowState) -> Double {
        streamState(in: window).durationMs
    }

    func currentSession(in window: WindowState) -> ChatSession? {
        guard let id = window.currentSessionId else { return nil }
        guard let summary = allSessionSummaries.first(where: { $0.id == id }) else { return nil }
        return summary.makeSession()
    }

    /// Check whether a given session is streaming in the background (not foreground) of this window
    func isBackgroundStreaming(_ sessionId: String, in window: WindowState) -> Bool {
        guard sessionId != (window.currentSessionId ?? window.newSessionKey) else { return false }
        return sessionStates[sessionId]?.isStreaming ?? false
    }

    /// Returns the set of session IDs currently streaming in the background of this window.
    func backgroundStreamingSessionIds(in window: WindowState) -> Set<String> {
        let currentKey = window.currentSessionId ?? window.newSessionKey
        return Set(sessionStates.compactMap { key, state in
            (state.isStreaming && key != currentKey) ? key : nil
        })
    }

    /// Derive a UI status for the chat row in the project sidebar.
    func chatStatus(forSessionId id: String, in window: WindowState) -> ChatStatus {
        if window.pendingPermissions.contains(where: { $0.sessionId == id }) {
            return .awaitingPermission
        }
        if let state = sessionStates[id] {
            if state.isStreaming { return .streaming }
            if state.hasUncheckedCompletion { return .done }
        }
        return .idle
    }

    func todoProgress(forSessionId id: String) -> ChatTodoProgress? {
        if let messages = sessionStates[id]?.messages,
           let todos = TodoExtractor.latest(in: messages)
        {
            return ChatTodoProgress(todos: todos)
        }

        guard let snapshot = threadStore.fetchTodoSnapshot(sessionId: id), snapshot.total > 0 else {
            return nil
        }

        return ChatTodoProgress(
            done: snapshot.done,
            total: snapshot.total,
            inProgress: snapshot.inProgress > 0
        )
    }

    // MARK: - Initialization

    /// Once per app launch — start services and load shared data
    func initialize() async {
        ThemeStore.shared.current = selectedTheme
        ThemeStore.shared.fontSizeAdjustment = fontSizeAdjustment
        ThemeStore.shared.messageFontSizeAdjustment = messageFontSizeAdjustment

        // Supply MobileSyncService with desktop-side context for the mobile
        // job Live Activity and home-screen widget pushes.
        MobileSyncService.shared.projectNameResolver = { [weak self] id in
            self?.projects.first { $0.id == id }?.name
        }
        MobileSyncService.shared.usageSnapshotProvider = { [weak self] in
            (
                cc: self?.latestRateLimitUsage?.fiveHourPercent,
                ccWeekly: self?.latestRateLimitUsage?.sevenDayPercent,
                codex: self?.latestCodexRateLimitUsage?.fiveHourPercent,
                codexWeekly: self?.latestCodexRateLimitUsage?.sevenDayPercent
            )
        }

        await refreshAgentInstallations()

        projects = await persistence.loadProjects()
        var seenPaths = Set<String>()
        let deduplicated = projects.filter { seenPaths.insert($0.path).inserted }
        if deduplicated.count != projects.count {
            projects = deduplicated
            try? await persistence.saveProjects(projects)
        }

        // Restore an existing rxauth session (token refresh runs silently).
        // One-time migration: purge the legacy GitHub device-flow access token
        // from the old `com.claudework.github` keychain entry so it never
        // gets re-used. `try?` — failure (no entry present) is the happy path.
        try? KeychainHelper.delete(service: "com.claudework.github", account: "access_token")
        // Restore an existing rxauth session. `OAuthManager.checkExistingAuth`
        // refreshes the access token if it has expired and starts its own
        // 5-minute refresh timer, so no extra scheduling is needed here.
        await rxAuth.restore()
        if isSignedIn {
            Task { [weak self] in await self?.loadRepos() }
        }

        // React to RxAuthSwift session expiry by clearing autopilot repos.
        // `isSignedIn`/`rxUser` are computed from the manager, so they update
        // automatically when `OAuthManager` flips to `.unauthenticated`.
        NotificationCenter.default.addObserver(
            forName: .rxAuthSessionExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repos = []
            }
        }

        marketplaceCustomSources = await marketplace.customSources()

        seedUITestBriefingIfRequested()

        // Sidebar threads are now sourced from the local SwiftData store.
        // CLI session files are no longer surfaced in the sidebar list — the
        // CLI is still the transcript backend (replay on thread open), but
        // it does not drive thread discovery.
        allSessionSummaries = threadStore.loadAllSummaries()
        autoArchiveExpiredSessionsIfNeeded()
        await autoDeleteExpiredSessionsIfNeeded()
        purgeStaleBranchBriefingsIfNeeded()

        persistedQueues = threadStore.loadAllQueues()

        if claudeInstalled || codexInstalled, !onboardingCompleted {
            onboardingCompleted = true
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        }

        // Hydrate ACP state (clients + cached registry) early so the model picker
        // and Settings tab don't flash empty on first open.
        await loadACPClientsFromDisk()
        Task { await self.refreshACPRegistry(forceRefresh: false) }

        permissionMode = Self.readPermissionModeFromSettings()

        do {
            try await permission.start()
        } catch {
            logger.error("Failed to start permission server: \(error.localizedDescription)")
        }

        // Warm MCP server statuses in the background so the Settings sheet
        // shows live connection results without the user clicking "Test".
        Task { [weak self] in
            await self?.refreshAndProbeAllMCPServers()
        }

        // Warm the rate-limit usage so the menu-bar label has data before the
        // popover is opened. RateLimitService caches for 5 minutes internally.
        Task { [weak self] in
            await self?.refreshRateLimitUsage()
            await self?.refreshCodexRateLimitUsage()
        }

        // Recurring probe so disconnected MCP servers surface promptly even
        // when the user isn't actively interacting with the Settings tab.
        startMCPPeriodicProbe()

        // Permission request routing is handled per-window in initializeWindow's listener.

        isInitialized = true
    }

    func refreshAgentInstallations() async {
        let claudeBinary = await claude.findClaudeBinary()
        claudeBinaryPath = claudeBinary
        claudeInstalled = claudeBinary != nil
        claudeVersion = nil

        if claudeBinary != nil {
            do {
                claudeVersion = try await claude.checkVersion()
            } catch {
                logger.warning("Failed to fetch Claude CLI version: \(error.localizedDescription)")
            }
        }

        let codexBinary = await codex.findCodexBinary()
        codexBinaryPath = codexBinary
        codexInstalled = codexBinary != nil
        codexVersion = nil

        if codexBinary != nil {
            do {
                codexVersion = try await codex.checkVersion()
                codexModels = await codex.fetchModels()
                logger.info("Codex CLI detected; fetched \(self.codexModels.count) Codex models")
                if codexModels.isEmpty {
                    logger.warning("Codex model discovery returned empty; using built-in Codex fallback models")
                }
                Task { [weak self] in
                    await self?.refreshCodexRateLimitUsage()
                }
            } catch {
                logger.warning("Failed to fetch Codex CLI version or models: \(error.localizedDescription)")
            }
        } else {
            codexModels = []
            logger.info("Codex CLI not detected; Codex model list cleared")
        }
    }

    func refreshOpenAISummarizationModels() async {
        let endpoint = openAISummarizationEndpoint
        let apiKey = openAISummarizationAPIKey

        isLoadingOpenAISummarizationModels = true
        openAISummarizationModelsError = nil
        defer { isLoadingOpenAISummarizationModels = false }

        do {
            let models = try await openAISummarization.fetchModels(endpoint: endpoint, apiKey: apiKey)
            openAISummarizationModels = models
            if openAISummarizationModel.isEmpty || !models.contains(openAISummarizationModel) {
                openAISummarizationModel = models.first ?? ""
            }
        } catch {
            openAISummarizationModelsError = error.localizedDescription
            logger.warning("Failed to fetch OpenAI summarization models: \(error.localizedDescription)")
        }
    }

    /// Per-window initialization — restore selected project and load session history
    func initializeWindow(_ window: WindowState, selectingProjectId: UUID? = nil) async {
        // Subscribe to permission broadcasts — appends requests to this window's pendingPermissions.
        // subscribe() issues a window-exclusive stream, so events are not stolen across multiple windows.
        Task { [weak self, weak window] in
            guard let self else { return }
            let (_, stream) = await self.permission.subscribe()
            for await request in stream {
                guard !Task.isCancelled else { break }
                guard let window else { break }
                if !window.pendingPermissions.contains(where: { $0.id == request.id }) {
                    window.pendingPermissions.append(request)
                    mobilePendingRequests[request.id] = request
                    let projectName = window.selectedProject?.name
                    let projectId = window.selectedProject?.id
                    let sessionId = window.currentSessionId
                    let toolName = request.toolName
                    if let requestSessionId = request.sessionId {
                        broadcastMobileSessionStatus(sessionID: requestSessionId)
                    }
                    if toolName == "AskUserQuestion" {
                        broadcastMobileQuestionQueue()
                    }
                    // Auto-present the question sheet only when the user is actively viewing
                    // the thread the question belongs to. Otherwise it stays in the queue
                    // (yellow dot in sidebar + banner) so the user can decide when to answer.
                    if toolName == "AskUserQuestion",
                       window.presentedPermissionId == nil,
                       let qSession = request.sessionId,
                       qSession == window.currentSessionId
                    {
                        window.presentedPermissionId = request.id
                    }
                    Task { @MainActor in
                        if toolName == "AskUserQuestion" {
                            await NotificationService.shared.postQuestionNeeded(
                                projectName: projectName,
                                projectId: projectId,
                                sessionId: sessionId
                            )
                        } else {
                            await NotificationService.shared.postPermissionNeeded(
                                toolName: toolName,
                                projectName: projectName,
                                projectId: projectId,
                                sessionId: sessionId
                            )
                        }
                    }
                }
            }
        }

        // Install the AskUserQuestion handlers. The question sheet calls submit when the
        // user finishes answering, and skip when they dismiss without answering.
        window.submitQuestionAnswersHandler = { [weak self, weak window] toolUseId, answers in
            guard let self, let window else { return }
            Task { await self.respondToAskUserQuestion(toolUseId: toolUseId, answers: answers, in: window) }
        }
        window.skipQuestionHandler = { [weak self, weak window] toolUseId in
            guard let self, let window else { return }
            Task { await self.skipAskUserQuestion(toolUseId: toolUseId, in: window) }
        }

        // Install the plan-card decision handler. The buttons on `PlanCardView` route
        // through here to resolve the ExitPlanMode hook and apply any follow-up mode change.
        window.planDecisionHandler = { [weak self, weak window] toolUseId, action in
            guard let self, let window else { return }
            Task { await self.respondToPlanDecision(toolUseId: toolUseId, action: action, in: window) }
        }

        // Hydrate per-window draft queues from disk-persisted queues so messages
        // typed-while-streaming survive an app relaunch.
        for (key, queue) in persistedQueues where window.draftQueues[key] == nil {
            window.draftQueues[key] = queue
        }

        if let projectId = selectingProjectId,
           let project = projects.first(where: { $0.id == projectId })
        {
            selectProject(project, in: window)
        } else if let savedId = UserDefaults.standard.string(forKey: "selectedProjectId"),
                  let uuid = UUID(uuidString: savedId),
                  let project = projects.first(where: { $0.id == uuid })
        {
            selectProject(project, in: window)
        } else if let first = projects.first {
            selectProject(first, in: window)
        }

        // Show the briefing as the landing view on launch, even after restoring a project.
        // `selectProject` clears `showingBriefing` for normal switches; re-enable here so the
        // user lands on the briefing dashboard rather than a fresh chat.
        window.showingBriefing = true

        window.isInitialized = true
    }

    func seedUITestBriefingIfRequested() {
        guard ProcessInfo.processInfo.environment["RXCODE_UI_TEST_SEED_BRIEFING"] == "1",
              let project = projects.first else {
            return
        }

        let branch = "main"
        threadStore.upsertThreadSummary(
            sessionId: "rxcode-ui-test-seeded-briefing-thread",
            projectId: project.id,
            branch: branch,
            title: "UI Test Seed Thread",
            summary: "Seeded thread summary for the briefing new-thread acceptance path."
        )
        threadStore.upsertBranchBriefing(
            projectId: project.id,
            branch: branch,
            briefing: "Seeded briefing for the local UI acceptance test."
        )
        threadSummaryRevision &+= 1
        branchBriefingRevision &+= 1
    }

    // MARK: - ChatBridge Setup

    /// Configures a `ChatBridge`'s action handlers and starts an observation loop that keeps
    /// the bridge's state properties in sync with the underlying `sessionStates`.
    func setupChatBridge(_ bridge: ChatBridge, for window: WindowState) {
        registerLiveWindow(window)
        bridge.sendHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            await self.send(in: window)
        }
        bridge.cancelStreamingHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            await self.cancelStreaming(in: window)
        }
        bridge.sendSlashCommandHandler = { [weak self, weak window] command in
            guard let self, let window else { return }
            await self.sendSlashCommand(command, in: window)
        }
        bridge.runTerminalCommandHandler = { [weak self, weak window] command in
            guard let self, let window else { return }
            await self.runTerminalCommand(command, in: window)
        }
        bridge.editAndResendHandler = { [weak self, weak window] messageId, newContent in
            guard let self, let window else { return }
            await self.editAndResend(messageId: messageId, newContent: newContent, in: window)
        }
        bridge.fetchRateLimitHandler = { [weak self] provider in
            await self?.rateLimitUsage(for: provider)
        }
        bridge.setSessionProviderHandler = { [weak self, weak window] provider in
            guard let self, let window else { return }
            self.setSessionProvider(provider, in: window)
        }
        bridge.togglePlanModeHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            self.toggleSessionPlanMode(in: window)
        }
        bridge.enqueueMessageHandler = { [weak self, weak window] text, attachments in
            guard let self, let window else { return }
            self.enqueueMessage(text: text, attachments: attachments, in: window)
        }
        bridge.removeQueuedMessageHandler = { [weak self, weak window] id in
            guard let self, let window else { return }
            self.removeQueuedMessage(id: id, in: window)
        }
        bridge.dequeueNextForFlushHandler = { [weak self, weak window] in
            guard let self, let window else { return nil }
            return self.dequeueNextForFlush(in: window)
        }
        bridge.sendQueuedNowHandler = { [weak self, weak window] id in
            guard let self, let window else { return }
            await self.sendQueuedNow(id: id, in: window)
        }
        bridge.sendAllQueuedAsOneHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            await self.sendAllQueuedAsOne(in: window)
        }

        startBridgeObservation(bridge, for: window)
    }

    /// Runs a reactive observation loop: reads AppState + WindowState properties into the bridge,
    /// then re-registers after each change. Stops when the bridge or window is deallocated.
    func startBridgeObservation(_ bridge: ChatBridge, for window: WindowState) {
        // Streaming state and global settings are observed in separate loops so that frequent
        // streaming updates don't trigger settings re-pushes (and vice versa).
        func observeStream() {
            withObservationTracking {
                let state = streamState(in: window)
                if bridge.messages.count != state.messages.count || bridge.isLoadingFromDisk != state.isLoadingFromDisk {
                    self.logger.info("[Bridge.observe] push sid=\(window.currentSessionId ?? "<nil>", privacy: .public) messages \(bridge.messages.count)→\(state.messages.count) loading \(bridge.isLoadingFromDisk)→\(state.isLoadingFromDisk) streaming=\(state.isStreaming)")
                }
                bridge.messages = state.messages
                bridge.isStreaming = state.isStreaming
                bridge.isThinking = state.isThinking
                bridge.isLoadingFromDisk = state.isLoadingFromDisk
                bridge.streamingStartDate = state.streamingStartDate
                bridge.liveOutputTokens = state.currentTurnOutputTokens
                bridge.lastTurnContextUsedPercentage = state.lastTurnContextUsedPercentage
                let selection = effectiveModelSelection(in: window)
                let provider = selection.provider
                let currentModel = selection.model
                bridge.agentProvider = provider
                bridge.modelDisplayName = modelDisplayName(for: currentModel, provider: provider, in: window)
                bridge.sessionStats = ChatSessionStats(
                    costUsd: state.costUsd,
                    inputTokens: state.inputTokens,
                    outputTokens: state.outputTokens,
                    cacheCreationTokens: state.cacheCreationTokens,
                    cacheReadTokens: state.cacheReadTokens,
                    durationMs: state.durationMs,
                    turns: state.turns
                )
                bridge.planDecisionSummaries = state.planDecisionSummaries
            } onChange: {
                Task { @MainActor in observeStream() }
            }
        }
        func observeSettings() {
            withObservationTracking {
                bridge.autoPreviewSettings = self.autoPreviewSettings
                bridge.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                bridge.claudeVersion = self.claudeVersion
                bridge.codexVersion = self.codexVersion
            } onChange: {
                Task { @MainActor in observeSettings() }
            }
        }
        Task { @MainActor in observeStream() }
        Task { @MainActor in observeSettings() }
    }

}
