import Foundation
import struct RxAgentSDK.ClaudeCodeClient
import os
import RxAuthSwift
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

struct ThreadFileEditsLoadID: Hashable {
    let sessionId: String
    let revision: Int
}

extension AppState {
    // MARK: - Private State

    // MARK: - Initialization

    func configureRuntimeServices(startBackgroundServices: Bool) {
        self.runService.onTasksChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.broadcastMobileRunTasks()
            }
        }

        installSDKBackendsIfEnabled()

        if startBackgroundServices && !AppSupport.isUnitTesting {
            // Bridge ACP `session/request_permission` and Codex in-band permission
            // requests into the existing PermissionServer.
            let permission = self.permission
            let codex = self.codex
            let ideMCPServer = self.ideMCPServer
            Task { [acp] in
                await acp.setPermissionServer(permission)
                await codex.setPermissionServer(permission)
                await ideMCPServer.setHandler(self)
            }

            // Boot the on-device thread search index in the background. The actor
            // loads cached chunks on `start`, then kicks off a one-time backfill
            // of any threads that don't have chunks yet.
            let searchService = self.searchService
            let memoryService = self.memoryService
            let keepsGlobalRows = self.activeWorkspace.isPersonal
            let threadStore = self.threadStore
            let threadStoreReader = self.threadStoreReader
            let persistence = self.persistence
            let workspaceDefaults = self.workspaceDefaults
            Task.detached(priority: .utility) { [weak self] in
                await searchService.setWorkspaceDefaults(workspaceDefaults)
                await searchService.start(threadStore: threadStore, reader: threadStoreReader)
                await memoryService.start(threadStore: threadStore, keepsGlobalRows: keepsGlobalRows)
                await searchService.backfillIfNeeded(
                    loadAll: { await threadStoreReader.loadSummaries() },
                    loadFull: { @MainActor [weak self] summary -> ChatSession? in
                        let cwd = self?.projects.first(where: { $0.id == summary.projectId })?.path ?? ""
                        return await persistence.loadFullSession(summary: summary, cwd: cwd)
                    }
                )
            }
        }
        // Mobile sync is owned by a single (frontmost) workspace — bound by
        // WorkspaceManager, not here, so multiple workspace windows don't all
        // respond to the same mobile request.

        // Build the hook controller/manager last — the controller captures
        // `self` (weakly) and every other service it forwards to is now ready.
        let hookController = AppStateHookController(app: self)
        self.hookController = hookController
        self.hookManager = HookManager(controller: hookController)
        self.reviewScheduler = ReviewScheduler(app: self)
        registerBuiltInHooks()
    }

    /// Once per app launch — start services and load shared data.
    ///
    /// Only the data the first frame renders is awaited here; everything else
    /// (agent discovery, sign-in restore, registries, store maintenance) runs
    /// alongside or after it. Launch previously sat on the splash screen
    /// through a `/bin/zsh -ilc` PATH probe, two CLI version checks, a Codex
    /// model round trip and a network token refresh before it began reading
    /// the sidebar's own data.
    func initialize() async {
        #if DEBUG
        if AppSupport.isScreenshotCapture {
            await initializeScreenshotWorkspace()
            return
        }
        #endif
        let launchStart = ContinuousClock.now
        async let cachedBranchStatus = CacheStorageService.shared.loadBranchStatus(workspaceID: activeWorkspace.id)

        ThemeStore.shared.current = selectedTheme
        // Settings forms in progress didn't survive the last quit.
        StudioModelConfig.clearPending()
        localModels.onModelInstalled = { [weak self] model in
            self?.generateStudioConfigAfterDownload(model)
        }
        ThemeStore.shared.fontSizeAdjustment = fontSizeAdjustment
        ThemeStore.shared.messageFontSizeAdjustment = messageFontSizeAdjustment

        // Services nothing on the critical path waits for, started first so
        // they overlap the loads below.
        if !AppSupport.isUnitTesting {
            startEagerBackgroundServices()
        }

        await persistence.migrateSessionsToGlobalStorage()
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
        let (snapshot, savedStatus) = await (threadStoreReader.loadStartupSnapshot(), cachedBranchStatus)
        allSessionSummaries = snapshot.summaries
        reviewPassedBySession = snapshot.reviewVerdicts
        threadFileEditPresence = snapshot.fileEditPresence
        todoProgressBySession = snapshot.todoProgress
        persistedQueues = snapshot.queues
        if !isInitialized {
            ciBranchesBySessionId = snapshot.branches
            restoreBranchStatus(savedStatus)
        }

        permissionMode = PermissionMode(rawValue: workspaceDefaults.string(for: "selectedPermissionMode") ?? "") ?? .default

        scheduleBriefingPlansRefresh()
        isInitialized = true
        if !AppSupport.isTestProcess { startCIStatusPoller() }
        scheduleDesktopWidgetUpdate()
        resumeReadyTaskDependencies()

        let elapsed = ContinuousClock.now - launchStart
        let elapsedMs = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        logger.info("Launch critical path took \(String(format: "%.0f", elapsedMs))ms (threads=\(self.allSessionSummaries.count) projects=\(self.projects.count))")

        // Hand the rest of the boot to a task so the window can finish coming
        // up (per-window init runs right after this returns).
        if !AppSupport.isUnitTesting {
            Task { [weak self] in await self?.finishInitialization() }
        }
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
                guard let self, rxAuth.manager.authState == .unauthenticated else { return }
                repos = []
                await clearCIStatus()
            }
        }

        if !AppSupport.isTestProcess {
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
                    startCIStatusPoller()
                } else {
                    await clearCIStatus()
                }
                // Keeps cloud projects' task boards in sync with Autopilot
                // (no-ops until signed in).
                startCloudProjectSync()
            }
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
        await loadScheduledTasksFromDisk()
        startScheduledTaskTimer()
        await loadBriefingNotificationSettings()
        await startUsagePlugins()
        Task { [weak self] in await self?.refreshACPRegistry(forceRefresh: false) }

        await runStartupStoreMaintenance()

        // Warm MCP server statuses in the background so the Settings sheet
        // shows live connection results without the user clicking "Test".
        Task { [weak self] in
            await self?.refreshAndProbeAllMCPServers()
        }

        // Warm the rate-limit usage so the menu-bar label has data before the
        // popover is opened.
        Task { [weak self] in
            await self?.refreshRateLimitUsage()
            await self?.refreshCodexRateLimitUsage()
        }
        startRateLimitSampling()

        // Recurring probe so disconnected MCP servers surface promptly even
        // when the user isn't actively interacting with the Settings tab.
        startMCPPeriodicProbe()
    }

    /// Launch-time store sweeps: project briefing metadata, then the
    /// archive/delete retention policy. These write, so they run on the main
    /// store rather than the background reader's context.
    func runStartupStoreMaintenance() async {
        let knownProjectIds = Set(sessionProjects.map(\.id))

        let prunedBriefingMetadata = threadStore.deleteBriefingMetadata(
            excludingProjectIds: knownProjectIds
        )
        if prunedBriefingMetadata.threadSummaries > 0 || prunedBriefingMetadata.branchBriefings > 0 {
            threadSummaryRevision &+= 1
            branchBriefingRevision &+= 1
            logger.info("Pruned orphan briefing metadata summaries=\(prunedBriefingMetadata.threadSummaries) briefings=\(prunedBriefingMetadata.branchBriefings)")
        }

        // Chats and their search entries are global and outlive their projects.

        autoArchiveExpiredSessionsIfNeeded()
        await autoDeleteExpiredSessionsIfNeeded()
        purgeStaleBranchBriefingsIfNeeded()
    }

    func refreshAgentInstallations() async {
        for provider in [AgentProvider.claudeCode, .codex] {
            reasoningLevelsByProvider.removeValue(forKey: provider)
            await loadReasoningLevels(for: provider)
        }
        let claudeBinary = await claude.findClaudeBinary()
        claudeBinaryPath = claudeBinary
        claudeInstalled = claudeBinary != nil
        claudeVersion = nil
        if let claudeBinary {
            claudeModels = await ClaudeCodeClient(binaryPath: claudeBinary).availableModels().map {
                AgentModel(provider: .claudeCode, id: $0.id, displayName: $0.displayName,
                           description: $0.modelDescription ?? "")
            }
        } else {
            claudeModels = []
        }

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
        let inspectorKey = selectingProjectId.map { "\(AppStorageKeys.rightInspectorLayout).project.\($0.uuidString)" }
            ?? AppStorageKeys.rightInspectorLayout
        window.restoreInspectorLayout(forKey: workspaceDefaults.key(inspectorKey))

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
                  let project = sessionProject(id: uuid)
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
        async let models: Void = refreshFlowcyModels()

        _ = await (repos, secrets, docs, ciUpdates, releases, models)
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
        bridge.resumeInterruptedTurnHandler = { [weak self, weak window] sessionID in
            guard let self, let window, window.currentSessionId == sessionID else { return }
            await self.resumeInterruptedTurn(in: window)
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
        bridge.deleteGenerationHandler = { [weak self] sessionID, messageID in
            guard let self else { throw CocoaError(.userCancelled) }
            try await self.deleteGeneration(sessionID: sessionID, messageID: messageID)
        }
        bridge.generateStudioConfigHandler = { [weak self] modelID, previous in
            guard let self else { throw CocoaError(.userCancelled) }
            return try await self.generateStudioConfig(modelID: modelID, previous: previous)
        }
        bridge.fetchLocalModelFooterHandler = { [weak self, weak window] in
            guard let self, let window else { return ("", 0, false, false) }
            let modelID = self.effectiveModelSelection(in: window).model
            let state = await self.localModels.manager.footerState(modelID: modelID)
            return (modelID, state.cached, state.preparing, state.canRelease)
        }
        bridge.releaseLocalModelHandler = { [weak self] modelID in
            guard let self else { return false }
            return await self.localModels.manager.releaseIfAvailable(modelID: modelID)
        }
        bridge.fetchLocalResourcesHandler = { [weak self, weak window] in
            guard let self, let window,
                  let model = self.localModels.model(id: self.effectiveModelSelection(in: window).model) else { return (nil, nil, nil) }
            // Video, image and audio models run as a short-lived engine
            // process per generation; decision models use the server.
            if model.studioKind.isStudio, model.studioKind != .decision {
                return (StableDiffusionProcess.memoryFootprint(), nil, nil)
            }
            let usage = await self.localModels.manager.resourceUsage(modelID: model.id)
            return (usage.memory, usage.gpu,
                    usage.context ?? min(self.localModels.effectiveContextSize,
                                         model.contextLength ?? self.localModels.effectiveContextSize))
        }
        bridge.accountRateLimits = core.accountRateLimits
        bridge.fetchRateLimitHandler = { [weak self] provider in
            await self?.rateLimitUsage(for: provider)
        }
        bridge.refreshACPUsageHandler = { [weak self, weak window] forceRefresh in
            guard let self, let window else { return }
            let selection = self.effectiveModelSelection(in: window)
            guard selection.provider == .acp else { return }
            let sessionClientID = self.streamState(in: window).acpClientId
            await self.refreshACPUsage(
                for: selection.model,
                clientID: sessionClientID,
                forceRefresh: forceRefresh
            )
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

        bridge.computerUseDecisionHandler = { [weak self, weak window] request, decision in
            guard let self, let window else { return }
            await self.respondToPermission(request, decision: decision, in: window)
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
                let workingDirectory = (state.isStreaming ? state.activeStreamCwd : nil) ?? effectiveCwd(in: window)
                if bridge.workingDirectory != workingDirectory {
                    bridge.workingDirectory = workingDirectory
                }
                bridge.isStreaming = state.isStreaming
                bridge.isThinking = state.isThinking
                bridge.isLoadingFromDisk = state.isLoadingFromDisk
                if !state.isStreaming, !state.isLoadingFromDisk, let id = window.currentSessionId,
                   allSessionSummaries.first(where: { $0.id == id })?.hasUnfinishedTurn == true {
                    bridge.interruptedSessionID = id
                } else {
                    bridge.interruptedSessionID = nil
                }
                bridge.streamingStartDate = state.streamingStartDate
                bridge.liveOutputTokens = state.currentTurnOutputTokens
                bridge.lastTurnContextUsedPercentage = state.lastTurnContextUsedPercentage
                let selection = effectiveModelSelection(in: window)
                let provider = selection.provider
                let currentModel = selection.model
                bridge.agentProvider = provider
                if bridge.selectedModelID != currentModel {
                    bridge.selectedModelID = currentModel
                }
                let supportsACP = provider == .acp ? supportsACPUsage(for: currentModel, clientID: state.acpClientId) : false
                if bridge.supportsACPUsage != supportsACP {
                    bridge.supportsACPUsage = supportsACP
                }
                let acpUsage = provider == .acp ? acpUsageSnapshot(for: currentModel, clientID: state.acpClientId) : nil
                if bridge.acpUsageSnapshot != acpUsage {
                    bridge.acpUsageSnapshot = acpUsage
                }
                bridge.canSteer = self.canSteer(in: window)
                bridge.modelDisplayName = modelDisplayName(for: currentModel, provider: provider, in: window)
                let studioKind = localStudioKind(currentModel, provider: provider)
                if bridge.studioKind != studioKind { bridge.studioKind = studioKind }
                let studioModelID = studioKind.isStudio ? currentModel : nil
                if bridge.studioModelID != studioModelID { bridge.studioModelID = studioModelID }
                let advice = rateLimitAdvice(for: provider, model: currentModel)
                if bridge.rateLimitAdvice != advice {
                    bridge.rateLimitAdvice = advice
                }
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
