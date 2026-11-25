import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Mobile Snapshot Broadcasting

extension AppState {
    func nextMobileSnapshotSeq() -> UInt64 {
        mobileSnapshotSeq &+= 1
        if mobileSnapshotSeq == 0 { mobileSnapshotSeq = 1 } // skip wraparound zero
        return mobileSnapshotSeq
    }

    func scheduleMobileSnapshotBroadcast() {
        mobileSnapshotBroadcastTask?.cancel()
        mobileSnapshotBroadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.broadcastMobileSnapshots()
        }
    }

    func broadcastMobileSnapshots() async {
        // Skip peers the relay has already told us are offline — sending to
        // them costs a round-trip just to get back `delivery_failed`, and on
        // remote relays that RTT (200ms+) adds up fast across 5+ peers.
        // Presence flips back to `.online` the moment any inbound payload
        // arrives, so a peer that comes back gets snapshots again
        // immediately.
        let targets = MobileSyncService.shared.pairedDevices
            .filter { $0.onlineState != .offline }
            .map(\.pubkeyHex)
        guard !targets.isEmpty else { return }
        for hex in targets {
            await sendMobileSnapshot(toHex: hex, activeSessionID: nil)
        }
    }

    func handleMobileSearchRequest(_ request: SearchRequestPayload, fromHex hex: String) async {
        let result = await combinedThreadAndDocsSearch(query: request.query, limit: request.limit)
        let payload = SearchResultsPayload(
            clientRequestID: request.clientRequestID,
            query: request.query,
            projectIDs: result.projectIDs,
            threadHits: result.threadHits,
            docHits: result.docHits
        )
        await MobileSyncService.shared.send(.searchResults(payload), toHex: hex)
    }

    /// Runs one query across both corpora the desktop owns: its on-device thread
    /// index (semantic + title match) and the rxlab docs service. Shared by the
    /// legacy `searchResults` relay and the `searchThreadsAndDocs` autopilot RPC
    /// so both stay in lockstep. Docs are best-effort — a signed-out desktop or a
    /// docs-service error collapses to an empty docs list and never fails the
    /// thread search. Mirrors the desktop overlay's global docs search
    /// (GlobalSearchOverlay).
    func combinedThreadAndDocsSearch(
        query: String,
        limit: Int
    ) async -> (projectIDs: [UUID], threadHits: [SearchHit], docHits: [DocsSearchHit]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], [], []) }

        let cappedLimit = max(limit, 1)
        let knownProjectIDs = Set(projects.map(\.id))
        let summaries = allSessionSummaries.filter { knownProjectIDs.contains($0.projectId) }
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })

        let semantic = await searchService.search(trimmed, limit: cappedLimit)

        var threadHitByID: [String: SearchHit] = [:]
        for group in semantic {
            for hit in group.hits {
                guard let summary = summaryByID[hit.threadId] else { continue }
                let title = ChatSession.stripAttachmentMarkers(from: summary.title)
                threadHitByID[hit.threadId] = SearchHit(
                    sessionID: hit.threadId,
                    projectID: hit.projectId,
                    title: title.isEmpty ? ChatSession.defaultTitle : title,
                    snippet: hit.snippet,
                    updatedAt: summary.updatedAt,
                    score: hit.score
                )
            }
        }

        let lowered = trimmed.lowercased()
        for summary in summaries where threadHitByID[summary.id] == nil {
            let cleaned = ChatSession.stripAttachmentMarkers(from: summary.title)
            guard cleaned.lowercased().contains(lowered) else { continue }
            let title = cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
            threadHitByID[summary.id] = SearchHit(
                sessionID: summary.id,
                projectID: summary.projectId,
                title: title,
                snippet: title,
                updatedAt: summary.updatedAt,
                score: 0
            )
        }

        let threadHits = threadHitByID.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(cappedLimit)

        let projectIDs = projects
            .filter { project in
                project.name.lowercased().contains(lowered)
                    || project.path.lowercased().contains(lowered)
            }
            .map(\.id)

        let docHits = (try? await docs.search(query: trimmed, repo: nil, limit: cappedLimit)) ?? []

        return (projectIDs, Array(threadHits), docHits)
    }

    func sendMobileSnapshot(toHex hex: String, activeSessionID: String?) async {
        await sendAgentHub(to: hex)
        // Populate the OpenAI summarization model list so mobile's model
        // picker has options. Fetched at most once — a prior failure (no API
        // key, bad endpoint) is recorded in `openAISummarizationModelsError`
        // and not retried on every snapshot.
        if summarizationProvider == .openAI,
           openAISummarizationModels.isEmpty,
           openAISummarizationModelsError == nil,
           !isLoadingOpenAISummarizationModels {
            await refreshOpenAISummarizationModels()
        }
        let active = await mobileActiveSessionPayload(for: activeSessionID)
        // Viewing a thread on any paired device counts as reading it: drop the
        // "finished, unread" flag so the green indicator clears on desktop and
        // mobile alike. Done before the snapshot is built so the payload below
        // already reflects the cleared state.
        if let activeID = active.id { markCompletionRead(for: activeID) }
        let branches = await mobileProjectBranches()
        // Warm the shared provider readings for mobile. Subsequent snapshots
        // reuse them, and observeMobileSnapshotInputs broadcasts fresh readings.
        Task { [weak self] in
            await self?.refreshRateLimitUsage()
            await self?.refreshCodexRateLimitUsage()
        }
        let hostMetrics = await SystemMetricsService.shared.sample()
        let runProfiles = await mobileRunProfiles()
        let runTasks = mobileRunTaskSnapshots()
        let webProxy = await localWebProxy.proxyInfo()
        let documentBriefings = await briefingStore.list()
            .filter(\.isPublished)
            .map { MobileBriefingDocument(
                id: $0.id, title: $0.title, format: $0.format.rawValue,
                projectId: $0.projectId, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            ) }
        if let webProxy {
            logger.info("[WebBrowserSync] snapshot includes web proxy host=\(webProxy.host, privacy: .public) port=\(webProxy.port, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        } else {
            logger.warning("[WebBrowserSync] snapshot has no web proxy info to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        }
        let sessions = await mobileSessionSummaries()
        guard !Task.isCancelled else { return }
        let knownProjectIDs = Set(projects.map(\.id))
        let payload = SnapshotPayload(
            projects: projects,
            sessions: sessions,
            branchBriefings: mobileBranchBriefings(),
            briefingPlans: briefingPlans.filter { knownProjectIDs.contains($0.projectID) },
            briefingDocuments: documentBriefings,
            usageDashboard: usageDashboard,
            threadSummaries: mobileThreadSummaries(),
            ciStatuses: mobileCIStatuses(),
            settings: mobileSettingsSnapshot(),
            activeSessionID: active.id,
            activeSessionMessages: active.messages,
            activeSessionHasMore: active.hasMore,
            projectBranches: branches,
            usage: MobileUsageSnapshot(
                claudeCode: latestRateLimitUsage,
                codex: latestCodexRateLimitUsage
            ),
            hostMetrics: hostMetrics,
            runProfiles: runProfiles,
            runTasks: runTasks,
            webProxy: webProxy,
            seq: nextMobileSnapshotSeq()
        )
        await MobileSyncService.shared.send(.snapshot(payload), toHex: hex)
        // The snapshot doesn't carry the question queue; send it alongside so a
        // freshly connected device renders any outstanding question banner.
        await MobileSyncService.shared.send(
            .questionQueue(QuestionQueuePayload(questions: mobilePendingQuestionPayloads())),
            toHex: hex
        )
        guard !mobileSyncObservers.isEmpty else { return }
        await MobileSyncService.shared.send(
            .confirmationQueue(ConfirmationQueuePayload(confirmations: mobilePendingConfirmationPayloads())),
            toHex: hex
        )
        logger.info(
            "[MobileSync] sent snapshot projects=\(self.projects.count, privacy: .public) sessions=\(payload.sessions.count, privacy: .public) runProfileProjects=\(runProfiles.count, privacy: .public) runProfileTotal=\(runProfiles.reduce(0) { $0 + $1.profiles.count }, privacy: .public) runTasks=\(runTasks.count, privacy: .public) active=\(active.id ?? "<nil>", privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)"
        )
    }

    func mobileSessionSummaries() async -> [RxCodeSync.SessionSummary] {
        let persisted = await threadStoreReader.loadMobileSessionData()
        // Agent conversations and subagent threads show in the phone's Chat tab.
        let knownProjectIds = Set(projects.map(\.id)).union(agentVirtualProjects.map(\.id))
        return allSessionSummaries
            .filter { knownProjectIds.contains($0.projectId) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map { summary in
                mobileSessionSummary(
                    from: summary,
                    todos: mobileTodoItems(forSessionId: summary.id, recorded: persisted.todos[summary.id]),
                    queued: persisted.queues[summary.id] ?? [],
                    changedFileCount: persisted.fileEditCounts[summary.id] ?? 0
                )
            }
    }

    func mobileSessionSummary(for sessionID: String) -> RxCodeSync.SessionSummary? {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return mobileSessionSummary(from: summary)
    }

    func mobileSessionSummary(from summary: ChatSession.Summary) -> RxCodeSync.SessionSummary {
        mobileSessionSummary(
            from: summary,
            todos: mobileTodoItems(forSessionId: summary.id),
            queued: threadStore.loadQueue(sessionKey: summary.id),
            changedFileCount: threadStore.fileEditCount(sessionId: summary.id)
        )
    }

    private func mobileSessionSummary(
        from summary: ChatSession.Summary,
        todos: [TodoItem]?,
        queued: [QueuedMessage],
        changedFileCount: Int
    ) -> RxCodeSync.SessionSummary {
        let state = stateForSession(summary.id)
        let provider = state.agentProvider ?? summary.agentProvider ?? selectedAgentProvider
        let sendMode: QueuedSendMode
        if state.isStreaming, !state.queueDispatchInProgress {
            let steer = canSteer(sessionID: summary.id, fallbackProvider: provider)
            sendMode = provider == .acp ? (steer ? .steerOrInterrupt : .interrupt) : (steer ? .steer : .wait)
        } else {
            sendMode = .wait
        }
        return RxCodeSync.SessionSummary(
            id: summary.id,
            projectId: summary.projectId,
            title: summary.title,
            updatedAt: summary.updatedAt,
            isPinned: summary.isPinned,
            isArchived: summary.isArchived,
            isStreaming: sessionStates[summary.id]?.isStreaming ?? false,
            attention: mobileAttentionKind(forSessionId: summary.id),
            progress: todos.map(mobileProgressSnapshot(for:)),
            todos: todos,
            queuedMessages: queued.map { QueuedUserMessage(id: $0.id, text: $0.text) },
            hasUncheckedCompletion: sessionStates[summary.id]?.hasUncheckedCompletion ?? false,
            isInterrupted: summary.hasUnfinishedTurn == true && sessionActivity[summary.id]?.isStreaming != true,
            parentThreadId: summary.parentThreadId,
            threadLabel: summary.threadLabel,
            changedFileCount: changedFileCount,
            queuedSendMode: sendMode
        )
    }

    func mobileProgressSnapshot(forSessionId id: String) -> SessionProgressSnapshot? {
        mobileTodoItems(forSessionId: id).map(mobileProgressSnapshot(for:))
    }

    private func mobileProgressSnapshot(for todos: [TodoItem]) -> SessionProgressSnapshot {
        SessionProgressSnapshot(
            done: todos.filter { $0.status == .completed }.count,
            total: todos.count,
            inProgress: todos.contains { $0.status == .inProgress }
        )
    }

    func mobileTodoItems(forSessionId id: String) -> [TodoItem]? {
        mobileTodoItems(forSessionId: id, recorded: threadStore.fetchTodoSnapshot(sessionId: id)?.list)
    }

    private func mobileTodoItems(forSessionId id: String, recorded: TodoListSnapshot?) -> [TodoItem]? {
        let transcript = sessionStates[id].flatMap { state in
            TodoExtractor.latestSnapshot(in: state.messages)
        }
        return TodoListSnapshot.latest(transcript: transcript, recorded: recorded)?.items
    }

    func mobileAttentionKind(forSessionId id: String) -> SessionAttentionKind? {
        let requests = mobilePendingRequests.values.filter { $0.sessionId.map(resolveCurrentSessionId) == id }
        if requests.contains(where: { $0.toolName == "AskUserQuestion" }) {
            return .question
        }
        if !requests.isEmpty {
            return .permission
        }
        return nil
    }

    /// Diff two message arrays for a session and emit `messageAppended` /
    /// `messageUpdated` payloads for each change. Called from `updateState`
    /// and `flushPendingUpdates` so every visible mutation reaches mobile
    /// without per-call site instrumentation.
    func broadcastMobileMessageDiff(
        sessionKey: String,
        prev: [ChatMessage],
        next: [ChatMessage],
        isStreaming: Bool
    ) {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        if prev.count == next.count, prev == next { return }
        // Diff against the raw messages (so a CLI result overwrite still counts
        // as a change), but bake the user-decision summary into the broadcast
        // copy so the mobile plan banner clears once a plan is resolved.
        let summaries = sessionStates[sessionKey]?.planDecisionSummaries ?? [:]
        let prevById = Dictionary(uniqueKeysWithValues: prev.map { ($0.id, $0) })
        for message in next {
            if let old = prevById[message.id] {
                guard old != message else { continue }
                MobileSyncService.shared.broadcastSessionUpdate(
                    sessionID: sessionKey,
                    kind: .messageUpdated,
                    message: messageWithPlanDecisions(message, summaries: summaries),
                    isStreaming: isStreaming
                )
            } else {
                MobileSyncService.shared.broadcastSessionUpdate(
                    sessionID: sessionKey,
                    kind: .messageAppended,
                    message: messageWithPlanDecisions(message, summaries: summaries),
                    isStreaming: isStreaming
                )
            }
        }
    }

    func broadcastMobileSessionStatus(sessionID: String, kind: SessionUpdatePayload.Kind = .statusChanged) {
        guard let summary = mobileSessionSummary(for: sessionID) else { return }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionID,
            kind: kind,
            message: nil,
            isStreaming: summary.isStreaming,
            summary: summary
        )
    }

    /// Detection may finish after streaming stops, so a streaming-status refresh
    /// alone can leave mobile's change overview and recorded-file count stale.
    func broadcastMobileFileEditsChanged(sessionID: String) {
        if mobileFullMessageCache?.sessionID == sessionID {
            mobileFullMessageCache = nil
        }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionID,
            kind: .statusChanged,
            message: nil,
            isStreaming: sessionStates[sessionID]?.isStreaming,
            summary: mobileSessionSummary(for: sessionID),
            fileEditsChanged: true
        )
    }

    /// Wire representation of every `AskUserQuestion` call currently awaiting an
    /// answer, used to mirror the desktop's question queue to mobile.
    func mobilePendingQuestionPayloads() -> [PendingQuestionPayload] {
        mobilePendingRequests.values
            .filter { $0.toolName == "AskUserQuestion" }
            .compactMap { request in
                guard let sessionId = request.sessionId,
                      let data = try? JSONEncoder().encode(request.toolInput),
                      let json = String(data: data, encoding: .utf8)
                else { return nil }
                return PendingQuestionPayload(
                    toolUseID: request.id,
                    sessionID: sessionId,
                    toolInputJSON: json
                )
            }
    }

    /// Broadcast the current `AskUserQuestion` queue to paired mobile devices.
    /// Called whenever the queue changes (a question is added or resolved) so
    /// mobile mirrors it exactly — additions and retractions alike.
    func broadcastMobileQuestionQueue() {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        MobileSyncService.shared.broadcastQuestionQueue(mobilePendingQuestionPayloads())
    }

    /// The same queue is sent on arrival, resolution and reconnect. The phone
    /// echoes the opaque prompt ID for both IDE and computer-use confirmations.
    func mobilePendingConfirmationPayloads() -> [PendingConfirmationPayload] {
        let idePrompts = agentPrompts.confirmations.map { confirmation in
            PendingConfirmationPayload(
                id: confirmation.id.uuidString,
                sessionID: resolveCurrentSessionId(confirmation.sessionKey),
                projectID: confirmation.projectId,
                title: confirmation.request.title,
                message: confirmation.request.message,
                confirmLabel: confirmation.request.confirmLabel,
                cancelLabel: confirmation.request.cancelLabel,
                isDestructive: confirmation.request.isDestructive
            )
        }
        let computerUsePrompts = mobilePendingRequests.values.sorted { $0.id < $1.id }.compactMap { request -> PendingConfirmationPayload? in
            guard ComputerUsePresentation.recognizes(request.toolName), let sessionID = request.sessionId else { return nil }
            return PendingConfirmationPayload(
                id: request.promptID.uuidString,
                sessionID: resolveCurrentSessionId(sessionID),
                projectID: projectID(forPromptSession: sessionID),
                title: String(localized: "Confirm computer use"),
                message: String(localized: "Allow the agent to control your Mac for the rest of this session?"),
                confirmLabel: String(localized: "Confirm for This Session"),
                cancelLabel: String(localized: "Reject"),
                isDestructive: false
            )
        }
        return idePrompts + computerUsePrompts
    }

    /// Broadcast the current confirmation queue to paired mobile devices.
    func broadcastMobileConfirmationQueue() {
        guard !mobileSyncObservers.isEmpty, !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        MobileSyncService.shared.broadcastConfirmationQueue(mobilePendingConfirmationPayloads())
    }

    func broadcastMobileSessionRedirect(from previousSessionID: String, to sessionID: String) {
        guard previousSessionID != sessionID,
              let summary = mobileSessionSummary(for: sessionID)
        else { return }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionID,
            kind: .statusChanged,
            message: nil,
            isStreaming: summary.isStreaming,
            summary: summary,
            previousSessionID: previousSessionID
        )
        scheduleMobileSnapshotBroadcast()
    }

    func mobileBranchBriefings() -> [MobileBranchBriefing] {
        let knownProjectIds = Set(projects.map(\.id))
        return threadStore.allBranchBriefingItems()
            .filter { knownProjectIds.contains($0.projectId) }
            .map {
                MobileBranchBriefing(
                    projectId: $0.projectId,
                    branch: $0.branch,
                    briefing: $0.briefing,
                    updatedAt: $0.updatedAt,
                    createdAt: $0.createdAt,
                    day: $0.day
                )
            }
    }

    func mobileThreadSummaries() -> [MobileThreadSummary] {
        let knownProjectIds = Set(projects.map(\.id))
        // Exclude `[Code Review]` threads — they aren't briefing threads.
        let reviewIds = codeReviewThreadIds
        return threadStore.allThreadSummaryItems()
            .filter { knownProjectIds.contains($0.projectId) && !reviewIds.contains($0.sessionId) }
            .map {
                MobileThreadSummary(
                    sessionId: $0.sessionId,
                    projectId: $0.projectId,
                    branch: $0.branch,
                    title: $0.title,
                    summary: $0.summary,
                    updatedAt: $0.updatedAt,
                    createdAt: $0.createdAt
                )
            }
    }

    func mobileCIStatuses() -> [MobileProjectCIStatus] {
        let knownProjectIds = Set(projects.map(\.id))
        return ciStatusByProject
            .filter { knownProjectIds.contains($0.key) }
            .map { MobileProjectCIStatus(projectId: $0.key, status: $0.value) }
            .sorted { lhs, rhs in
                let leftName = projects.first(where: { $0.id == lhs.projectId })?.name ?? ""
                let rightName = projects.first(where: { $0.id == rhs.projectId })?.name ?? ""
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
    }

    func mobileSettingsSnapshot() -> MobileSettingsSnapshot {
        // Tasks launched from mobile run on this Mac, including local agents.
        let sections = availableAgentModelSections(includeFlowcy: true).map {
            AgentModelSection(
                id: $0.id,
                title: $0.title,
                provider: $0.provider,
                iconURL: $0.iconURL,
                models: $0.models
            )
        }
        let models = sections.flatMap(\.models)
        var levelsByModel: [String: [ReasoningLevel]] = [:]
        for model in models {
            levelsByModel[model.key] = reasoningLevels(for: model.provider, model: model.id)
        }
        return MobileSettingsSnapshot(
            selectedAgentProvider: selectedAgentProvider,
            selectedModel: defaultModelSelection(for: nil).model,
            selectedACPClientId: selectedACPClientId,
            selectedEffort: selectedEffort,
            permissionMode: permissionMode,
            summarizationProvider: summarizationProvider.rawValue,
            summarizationProviderDisplayName: summarizationProvider.displayNameText,
            openAISummarizationEndpoint: openAISummarizationEndpoint,
            openAISummarizationModel: openAISummarizationModel,
            notificationsEnabled: notificationsEnabled,
            focusMode: focusMode,
            autoArchiveEnabled: autoArchiveEnabled,
            archiveRetentionDays: archiveRetentionDays,
            autoPreviewSettings: autoPreviewSettings,
            availableEfforts: ["auto"] + availableEfforts,
            reasoningLevelsByModel: levelsByModel,
            availableModels: models,
            modelSections: sections,
            availableSummarizationProviders: SummarizationProvider.availableCases.map {
                SummarizationProviderOption(id: $0.rawValue, displayName: $0.displayNameText)
            },
            openAISummarizationModels: openAISummarizationModels
        )
    }

    /// Resolve the current git branch and the local branch list for each known
    /// project. Runs the per-project git calls concurrently so a large project
    /// list doesn't serialize on disk I/O.
    func mobileProjectBranches() async -> [ProjectBranchInfo] {
        let inputs = projects.map { (id: $0.id, path: $0.path) }
        return await withTaskGroup(of: ProjectBranchInfo?.self) { group in
            for input in inputs {
                group.addTask {
                    async let current = GitHelper.currentBranch(at: input.path)
                    async let list = GitHelper.listLocalBranches(at: input.path)
                    async let status = GitHelper.run(["status", "--porcelain"], at: input.path)
                    guard let branch = await current else { return nil }
                    let branches = await list
                    // `nil` (git call failed / not a repo) stays "unknown" so the
                    // Commit All action isn't hidden on a transient git error.
                    let dirty = (await status).map {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return ProjectBranchInfo(
                        projectId: input.id,
                        currentBranch: branch,
                        availableBranches: branches.isEmpty ? nil : branches,
                        hasUncommittedChanges: dirty
                    )
                }
            }
            var result: [ProjectBranchInfo] = []
            for await info in group {
                if let info { result.append(info) }
            }
            return result
        }
    }

    func applyMobileSettingsUpdate(_ update: MobileSettingsUpdatePayload) {
        if let provider = update.selectedAgentProvider {
            selectedAgentProvider = provider
        }
        if let model = update.selectedModel {
            selectedModel = model
        }
        if let clientId = update.selectedACPClientId {
            selectedACPClientId = clientId
        }
        if let effort = update.selectedEffort, effort == "auto" || availableEfforts.contains(effort) {
            selectedEffort = effort
        }
        if let mode = update.permissionMode {
            permissionMode = mode
        }
        if let rawProvider = update.summarizationProvider,
           let provider = SummarizationProvider(rawValue: rawProvider),
           SummarizationProvider.availableCases.contains(provider) {
            summarizationProvider = provider
        }
        if let model = update.openAISummarizationModel {
            openAISummarizationModel = model
        }
        if let enabled = update.notificationsEnabled {
            notificationsEnabled = enabled
        }
        if let enabled = update.focusMode {
            focusMode = enabled
        }
        if let enabled = update.autoArchiveEnabled {
            autoArchiveEnabled = enabled
        }
        if let days = update.archiveRetentionDays {
            archiveRetentionDays = max(1, min(365, days))
        }
        if let previews = update.autoPreviewSettings {
            autoPreviewSettings = previews
        }
    }

    /// User-triggered full reindex of every thread. Wipes cached embeddings,
    /// then re-embeds every thread. Updates `reindexProgress` so the UI can
    /// render a counter.
    func reindexAllThreads() async {
        guard reindexProgress == nil else { return }
        reindexProgress = (0, 0)
        let searchService = self.searchService
        let threadStore = self.threadStore
        let persistence = self.persistence
        await searchService.reindexAll(
            loadAll: { @MainActor in threadStore.loadAllSummaries() },
            loadFull: { @MainActor [weak self] summary -> ChatSession? in
                let cwd = self?.projects.first(where: { $0.id == summary.projectId })?.path ?? ""
                return await persistence.loadFullSession(summary: summary, cwd: cwd)
            },
            progress: { [weak self] done, total in
                Task { @MainActor [weak self] in self?.reindexProgress = (done, total) }
            }
        )
        reindexProgress = nil
    }

}
