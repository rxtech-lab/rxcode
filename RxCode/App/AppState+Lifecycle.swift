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
        return threadStore.fetchFileEdits(sessionId: key)
            .map { $0.toSummary() }
            .filter { !PlanLogic.isPlanFilePath($0.path) }
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
        // `sessionActivity`, not `sessionStates`: this runs in every sidebar row's
        // body, and reading `sessionStates` re-rendered them all per stream event.
        if let activity = sessionActivity[id] {
            if activity.isStreaming { return .streaming }
            if activity.hasUncheckedCompletion { return .done }
        }
        return .idle
    }

    func todoProgress(forSessionId id: String) -> ChatTodoProgress? {
        // Live todos are extracted off the hot path into `sessionActivity`
        // instead of rescanning the whole transcript per row per render.
        if let todos = liveTodos(forSessionId: id) {
            return ChatTodoProgress(todos: todos)
        }

        // Read the persisted fallback from the in-memory index rather than
        // fetching per call: the sidebar asks this for every visible thread on
        // every view-graph update, where a SwiftData fetch would land on the
        // main thread at display-link rate.
        guard let snapshot = todoProgressBySession[id], snapshot.total > 0 else {
            return nil
        }

        return snapshot
    }

    /// Reload the todo-snapshot index from SwiftData. Driven by
    /// `todoSnapshotsRevision`, so every existing bump site keeps the index fresh
    /// without also having to remember to refresh it.
    func refreshTodoSnapshotIndex() {
        let progress = threadStore.loadTodoProgressBySession()
        // Assigning an equal value still fires observation, and this runs on every
        // todo write — only publish when the answer actually changed.
        guard progress != todoProgressBySession else { return }
        todoProgressBySession = progress
    }

    // MARK: - Initialization

    /// Once per app launch — start services and load shared data.
    ///
    /// Only the data the first frame renders is awaited here; everything else
    /// (agent discovery, sign-in restore, registries, store maintenance) runs
    /// alongside or after it. Launch previously sat on the splash screen
    /// through a `/bin/zsh -ilc` PATH probe, two CLI version checks, a Codex
    /// model round trip and a network token refresh before it began reading
    /// the sidebar's own data.
    func initialize() async {
        let launchStart = ContinuousClock.now

        ThemeStore.shared.current = selectedTheme
        ThemeStore.shared.fontSizeAdjustment = fontSizeAdjustment
        ThemeStore.shared.messageFontSizeAdjustment = messageFontSizeAdjustment

        // Services nothing on the critical path waits for, started first so
        // they overlap the loads below.
        startEagerBackgroundServices()

        projects = await loadDeduplicatedProjects()
        seedUITestBriefingIfRequested()

        // Task boards back the landing surface, so they load with the project
        // list. Decoding happens inside the persistence actor.
        await loadAllTaskBoards()

        // Sidebar threads are sourced from the local SwiftData store. The CLI
        // is still the transcript backend (replay on thread open), but it does
        // not drive thread discovery.
        //
        // Every index the sidebar reads — summaries, review verdicts, the
        // file-edit and todo indexes, queued drafts — is fetched in a single
        // pass on a background context, so a store with thousands of rows no
        // longer blocks the main thread while the window comes up.
        let snapshot = await threadStoreReader.loadStartupSnapshot()
        allSessionSummaries = snapshot.summaries
        reviewPassedBySession = snapshot.reviewVerdicts
        sessionIdsWithFileEdits = snapshot.sessionIdsWithFileEdits
        todoProgressBySession = snapshot.todoProgress
        persistedQueues = snapshot.queues

        permissionMode = PermissionMode(rawValue: workspaceDefaults.string(for: "selectedPermissionMode") ?? "") ?? .default

        // Permission request routing is handled per-window in initializeWindow's listener.
        isInitialized = true

        let elapsed = ContinuousClock.now - launchStart
        let elapsedMs = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        logger.info("Launch critical path took \(String(format: "%.0f", elapsedMs))ms (threads=\(self.allSessionSummaries.count) projects=\(self.projects.count))")

        // Hand the rest of the boot to a task so the window can finish coming
        // up (per-window init runs right after this returns).
        Task { [weak self] in await self?.finishInitialization() }
    }

    /// Work that has to start as early as possible but that the first frame
    /// does not read: the permission server, agent discovery, and sign-in.
    private func startEagerBackgroundServices() {
        // Prewarm each backend's shell PATH cache in parallel so the first
        // user message in a thread doesn't pay the `/bin/zsh -ilc` round trip
        // on its critical path. All three share `ShellPathResolver`, so this is
        // one shell spawn — and none at all once a previous launch has
        // remembered the PATH.
        Task { [claude, codex, acp] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await claude.prewarm() }
                group.addTask { await codex.prewarm() }
                group.addTask { await acp.prewarm() }
            }
        }

        // CLI discovery spawns `claude --version`, `codex --version` and a
        // Codex `model/list` round trip. Settings and the model picker read the
        // results; nothing on the launch path does.
        Task { [weak self] in await self?.refreshAgentInstallations() }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await permission.start()
            } catch {
                logger.error("Failed to start permission server: \(error.localizedDescription)")
            }
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

        Task { [weak self] in
            guard let self else { return }
            // Restore an existing rxauth session (token refresh runs silently).
            // One-time migration: purge the legacy GitHub device-flow access
            // token from the old `com.claudework.github` keychain entry so it
            // never gets re-used. Runs off the main actor and only until it
            // succeeds (a missing entry counts): a `SecItem` call can block for
            // seconds on a keychain permission prompt, which froze launch.
            let legacyTokenPurgedKey = "didPurgeLegacyGitHubAccessToken"
            if !UserDefaults.standard.bool(forKey: legacyTokenPurgedKey) {
                Task.detached(priority: .utility) {
                    if (try? KeychainHelper.delete(service: "com.claudework.github", account: "access_token")) != nil {
                        UserDefaults.standard.set(true, forKey: legacyTokenPurgedKey)
                    }
                }
            }
            // `OAuthManager.checkExistingAuth` refreshes the access token if it
            // has expired and starts its own 5-minute refresh timer, so no
            // extra scheduling is needed here.
            await rxAuth.restore()
            if isSignedIn {
                startAutopilotWarmup()
            }
            // Periodically pull GitHub Actions CI status for open projects
            // (no-ops until signed in). Notifies on failure and, when enabled,
            // auto-starts a fix thread.
            startCIStatusPoller()
        }
    }

    /// Everything that can wait until the window is on screen: registries,
    /// retention policy, and the store sweeps that keep orphan rows out of
    /// history and search.
    private func finishInitialization() async {
        marketplaceCustomSources = await marketplace.customSources()

        // Hydrate ACP state (clients + cached registry) so the model picker and
        // Settings tab don't flash empty on first open.
        await loadACPClientsFromDisk()
        Task { [weak self] in await self?.refreshACPRegistry(forceRefresh: false) }

        await runStartupStoreMaintenance()

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
    }

    /// Launch-time store sweeps: orphan rows from deleted projects, then the
    /// archive/delete retention policy. These write, so they run on the main
    /// store rather than the background reader's context.
    private func runStartupStoreMaintenance() async {
        let knownProjectIds = Set(projects.map(\.id))

        let prunedBriefingMetadata = threadStore.deleteBriefingMetadata(
            excludingProjectIds: knownProjectIds
        )
        if prunedBriefingMetadata.threadSummaries > 0 || prunedBriefingMetadata.branchBriefings > 0 {
            threadSummaryRevision &+= 1
            branchBriefingRevision &+= 1
            logger.info("Pruned orphan briefing metadata summaries=\(prunedBriefingMetadata.threadSummaries) briefings=\(prunedBriefingMetadata.branchBriefings)")
        }

        // Purge threads + search chunks left behind by projects that were
        // deleted before the cascade in `deleteProject` existed (or by any
        // leak). This clears them from history and the search source so they
        // never resurface as "Unknown project" results.
        let prunedOrphanThreads = threadStore.pruneOrphanThreads(excludingProjectIds: knownProjectIds)
        if prunedOrphanThreads > 0 {
            logger.info("Pruned \(prunedOrphanThreads) orphan thread(s) from deleted projects")
            // The sidebar list was published before this sweep ran — reload it
            // so the pruned threads drop out.
            allSessionSummaries = await threadStoreReader.loadSummaries()
        }
        // Keep the in-memory search index consistent too (disk is already clean
        // above). Detached so the boot isn't blocked on the embedding actor.
        Task.detached(priority: .utility) { [searchService] in
            await searchService.pruneOrphans(knownProjectIds: knownProjectIds)
        }

        autoArchiveExpiredSessionsIfNeeded()
        await autoDeleteExpiredSessionsIfNeeded()
        purgeStaleBranchBriefingsIfNeeded()
    }

    /// Projects as persisted, minus duplicate paths (rewriting the file when a
    /// duplicate is dropped).
    private func loadDeduplicatedProjects() async -> [Project] {
        let loaded = await persistence.loadProjects()
        var seenPaths = Set<String>()
        let deduplicated = loaded.filter { seenPaths.insert($0.path).inserted }
        guard deduplicated.count != loaded.count else { return loaded }
        try? await persistence.saveProjects(deduplicated)
        return deduplicated
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

        await refreshAgentSignInStatus()
    }

    /// Re-read each CLI's stored credentials so settings can offer
    /// "Re-sign In" instead of "Sign In" when an account is already linked.
    func refreshAgentSignInStatus() async {
        let claude = claude, codex = codex
        let checkClaude = claudeInstalled, checkCodex = codexInstalled
        async let claudeSignedIn = checkClaude ? claude.isSignedIn() : false
        async let codexSignedIn = checkCodex ? codex.isSignedIn() : false
        self.claudeSignedIn = await claudeSignedIn
        self.codexSignedIn = await codexSignedIn
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
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if toolName == "AskUserQuestion" {
                            await self.hookManager.dispatchQuestionAsk(QuestionAskPayload(
                                toolUseId: request.id,
                                sessionId: sessionId,
                                projectId: projectId,
                                projectName: projectName
                            ))
                        } else {
                            await self.hookManager.dispatchPermissionAsk(PermissionAskPayload(
                                toolUseId: request.id,
                                toolName: toolName,
                                sessionId: sessionId,
                                projectId: projectId,
                                projectName: projectName
                            ))
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

        // Install the review-countdown handler. The Stop / Start-now buttons on
        // the countdown card route through here to the review scheduler.
        window.reviewCountdownHandler = { [weak self] parentSessionKey, action in
            guard let self else { return }
            switch action {
            case .startNow: self.reviewScheduler.startNow(parentSessionKey: parentSessionKey)
            case .stop: self.reviewScheduler.cancel(parentSessionKey: parentSessionKey, reason: .stopButton)
            }
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
        } else if let savedId = workspaceDefaults.string(for: "selectedProjectId"),
                  let uuid = UUID(uuidString: savedId),
                  let project = projects.first(where: { $0.id == uuid })
        {
            selectProject(project, in: window)
        } else if let first = projects.first {
            selectProject(first, in: window)
        }

        // Show the task board as the landing view on launch, even after restoring a
        // project. `selectProject` clears `generalRoute` for normal switches; re-set it
        // here so the user lands on the board rather than a fresh chat.
        window.generalRoute = .tasks

        window.isInitialized = true
    }

    /// Starts the Autopilot-backed reads that power repo import, hook banners,
    /// and briefing-card chips. This intentionally runs during app
    /// initialization so the desktop loading screen can hide most of the network
    /// latency instead of waiting for sidebar views to appear.
    func startAutopilotWarmup() {
        Task { [weak self] in
            await self?.refreshAutopilotLaunchData()
        }
    }

    private func refreshAutopilotLaunchData() async {
        guard isSignedIn else { return }

        async let repos: Void = loadRepos()
        async let secrets: Void = refreshSecretsStatuses()
        async let docs: Void = refreshDocsStatuses()
        async let ciUpdates: Void = refreshCIStatuses()
        async let releases: Void = refreshReleaseStatuses()

        _ = await (repos, secrets, docs, ciUpdates, releases)
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
        bridge.steerQueuedMessageHandler = { [weak self, weak window] id in
            guard let self, let window else { return false }
            return await self.steerQueuedMessage(id: id, in: window)
        }
        bridge.steerAllQueuedAsOneHandler = { [weak self, weak window] in
            guard let self, let window else { return false }
            return await self.steerAllQueuedAsOne(in: window)
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
                bridge.canSteer = self.canSteer(in: window)
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
