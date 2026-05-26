import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Mobile Snapshot Broadcasting

extension AppState {
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
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let empty = SearchResultsPayload(
                clientRequestID: request.clientRequestID,
                query: request.query,
                projectIDs: [],
                threadHits: []
            )
            await MobileSyncService.shared.send(.searchResults(empty), toHex: hex)
            return
        }

        let knownProjectIDs = Set(projects.map(\.id))
        let summaries = allSessionSummaries.filter { knownProjectIDs.contains($0.projectId) }
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })

        let semantic = await searchService.search(trimmed, limit: max(request.limit, 1))

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
            .prefix(max(request.limit, 1))

        let projectIDs = projects
            .filter { project in
                project.name.lowercased().contains(lowered)
                    || project.path.lowercased().contains(lowered)
            }
            .map(\.id)

        let payload = SearchResultsPayload(
            clientRequestID: request.clientRequestID,
            query: request.query,
            projectIDs: projectIDs,
            threadHits: Array(threadHits)
        )
        await MobileSyncService.shared.send(.searchResults(payload), toHex: hex)
    }

    func sendMobileSnapshot(toHex hex: String, activeSessionID: String?) async {
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
        if let activeID = active.id, sessionStates[activeID]?.hasUncheckedCompletion == true {
            updateState(activeID) { $0.hasUncheckedCompletion = false }
        }
        let branches = await mobileProjectBranches()
        // Keep mobile usage reasonably fresh. Non-forced — RateLimitService's
        // 5-minute cache turns this into a no-op when usage was fetched
        // recently, so frequent snapshots don't translate into API calls. A
        // genuine refresh updates `latestRateLimitUsage`, which
        // `observeMobileSnapshotInputs` tracks, re-broadcasting the snapshot.
        Task { [weak self] in
            await self?.refreshRateLimitUsage()
            await self?.refreshCodexRateLimitUsage()
        }
        let hostMetrics = await SystemMetricsService.shared.sample()
        let runProfiles = await mobileRunProfiles()
        let runTasks = mobileRunTaskSnapshots()
        let webProxy = await localWebProxy.proxyInfo()
        if let webProxy {
            logger.info("[WebBrowserSync] snapshot includes web proxy host=\(webProxy.host, privacy: .public) port=\(webProxy.port, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        } else {
            logger.warning("[WebBrowserSync] snapshot has no web proxy info to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        }
        let payload = SnapshotPayload(
            projects: projects,
            sessions: mobileSessionSummaries(),
            branchBriefings: mobileBranchBriefings(),
            threadSummaries: mobileThreadSummaries(),
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
        logger.info(
            "[MobileSync] sent snapshot projects=\(self.projects.count, privacy: .public) sessions=\(payload.sessions.count, privacy: .public) runProfileProjects=\(runProfiles.count, privacy: .public) runProfileTotal=\(runProfiles.reduce(0) { $0 + $1.profiles.count }, privacy: .public) runTasks=\(runTasks.count, privacy: .public) active=\(active.id ?? "<nil>", privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)"
        )
    }

    func mobileSessionSummaries() -> [RxCodeSync.SessionSummary] {
        let knownProjectIds = Set(projects.map(\.id))
        return allSessionSummaries
            .filter { knownProjectIds.contains($0.projectId) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map {
                mobileSessionSummary(from: $0)
            }
    }

    func mobileRunProfiles() async -> [MobileProjectRunProfiles] {
        var result: [MobileProjectRunProfiles] = []
        for project in projects {
            await ensureRunProfilesLoaded(for: project.id)
            let profiles = runProfiles(for: project.id)
            result.append(MobileProjectRunProfiles(
                projectId: project.id,
                profiles: profiles
            ))
        }
        return result
    }

    func mobileRunTaskSnapshots() -> [MobileRunTaskSnapshot] {
        runService.tasks.map(mobileRunTaskSnapshot)
    }

    func mobileRunTaskSnapshot(_ task: RunTask) -> MobileRunTaskSnapshot {
        MobileRunTaskSnapshot(
            taskId: task.id,
            projectId: task.project.id,
            profileId: task.profile.id,
            profileName: task.profile.name,
            status: mobileRunTaskStatus(task.status),
            statusLabel: task.status.label,
            exitCode: task.exitCode,
            startedAt: task.startedAt,
            resolvedCwd: task.resolvedCwd,
            commandPreview: mobileRunTaskCommandPreview(task),
            terminalOutputTail: String(task.terminalOutputTail.suffix(8_000))
        )
    }

    func mobileRunTaskStatus(_ status: RunTaskStatus) -> MobileRunTaskSnapshot.Status {
        switch status {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .signaled: return .signaled
        case .stopped: return .stopped
        }
    }

    func mobileRunTaskCommandPreview(_ task: RunTask) -> String {
        let lines = task.wrapperScript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let mainIndex = lines.firstIndex(of: "# --- main ---") {
            return lines.dropFirst(mainIndex + 1)
                .prefix(8)
                .joined(separator: "\n")
        }
        return lines.suffix(8).joined(separator: "\n")
    }

    func broadcastMobileRunTasks() {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        let currentSnapshots = runService.tasks.prefix(5).map(mobileRunTaskSnapshot)
        let currentById = Dictionary(uniqueKeysWithValues: currentSnapshots.map { ($0.taskId, $0) })
        let removedIds = Set(lastBroadcastRunTaskSnapshots.keys).subtracting(currentById.keys)
        if !removedIds.isEmpty {
            scheduleMobileSnapshotBroadcast()
        }
        for snapshot in currentSnapshots where lastBroadcastRunTaskSnapshots[snapshot.taskId] != snapshot {
            MobileSyncService.shared.broadcastRunTaskUpdate(snapshot)
        }
        lastBroadcastRunTaskSnapshots = currentById
    }

    func mobileSessionSummary(for sessionID: String) -> RxCodeSync.SessionSummary? {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return mobileSessionSummary(from: summary)
    }

    func mobileSessionSummary(from summary: ChatSession.Summary) -> RxCodeSync.SessionSummary {
        let todos = mobileTodoItems(forSessionId: summary.id)
        let progress = mobileProgressSnapshot(forSessionId: summary.id)
        let queued = threadStore.loadQueue(sessionKey: summary.id).map {
            QueuedUserMessage(id: $0.id, text: $0.text)
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
            progress: progress,
            todos: todos,
            queuedMessages: queued,
            hasUncheckedCompletion: sessionStates[summary.id]?.hasUncheckedCompletion ?? false
        )
    }

    func mobileProgressSnapshot(forSessionId id: String) -> SessionProgressSnapshot? {
        if let todos = mobileTodoItems(forSessionId: id) {
            return SessionProgressSnapshot(
                done: todos.filter { $0.status == .completed }.count,
                total: todos.count,
                inProgress: todos.contains { $0.status == .inProgress }
            )
        }

        return nil
    }

    func mobileTodoItems(forSessionId id: String) -> [TodoItem]? {
        if let messages = sessionStates[id]?.messages,
           let todos = TodoExtractor.latest(in: messages)
        {
            return todos
        }

        guard let snapshot = threadStore.fetchTodoSnapshot(sessionId: id), snapshot.total > 0 else {
            return nil
        }

        return snapshot.items
    }

    func mobileAttentionKind(forSessionId id: String) -> SessionAttentionKind? {
        let requests = mobilePendingRequests.values.filter { $0.sessionId == id }
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
                    updatedAt: $0.updatedAt
                )
            }
    }

    func mobileThreadSummaries() -> [MobileThreadSummary] {
        let knownProjectIds = Set(projects.map(\.id))
        return threadStore.allThreadSummaryItems()
            .filter { knownProjectIds.contains($0.projectId) }
            .map {
                MobileThreadSummary(
                    sessionId: $0.sessionId,
                    projectId: $0.projectId,
                    branch: $0.branch,
                    title: $0.title,
                    summary: $0.summary,
                    updatedAt: $0.updatedAt
                )
            }
    }

    func mobileSettingsSnapshot() -> MobileSettingsSnapshot {
        let sections = availableAgentModelSections().map {
            AgentModelSection(
                id: $0.id,
                title: $0.title,
                provider: $0.provider,
                iconURL: $0.iconURL,
                models: $0.models
            )
        }
        let models = sections.flatMap(\.models)
        return MobileSettingsSnapshot(
            selectedAgentProvider: selectedAgentProvider,
            selectedModel: selectedModel,
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
            availableEfforts: ["auto"] + Self.availableEfforts,
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
                    guard let branch = await current else { return nil }
                    let branches = await list
                    return ProjectBranchInfo(
                        projectId: input.id,
                        currentBranch: branch,
                        availableBranches: branches.isEmpty ? nil : branches
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
        if let effort = update.selectedEffort, effort == "auto" || Self.availableEfforts.contains(effort) {
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

    /// Number of messages in one mobile history page. Mobile loads the most
    /// recent page on subscribe and requests older pages as the user scrolls up.
    static let mobileMessagePageSize = 30

    /// Encoded byte ceiling for the message slice carried in one sync frame.
    /// The relay caps a WebSocket frame at 10 MiB and the encrypted envelope
    /// inflates the plaintext by roughly a third (base64), so an oversized
    /// snapshot would have `task.send` throw and be silently dropped — leaving
    /// mobile with only the live stream and no history. Holding the message
    /// slice to 3 MiB leaves ample room for the rest of the snapshot (projects,
    /// session summaries, briefings) and the envelope overhead; older messages
    /// beyond the budget are paged in on demand via `load_more_messages`.
    static let mobileMessagePageByteBudget = 3 * 1024 * 1024

    /// Largest suffix of `messages[..<end]` that fits both the page-count and
    /// byte budgets, walking newest-first. At least one message is always
    /// returned so paging can still advance even on a pathologically large
    /// message. Returns the page and the index it starts at — a non-zero start
    /// means older messages remain.
    func mobileMessagePage(
        from messages: [ChatMessage],
        endingAt end: Int,
        countLimit: Int
    ) -> (page: [ChatMessage], startIndex: Int) {
        let clampedEnd = min(max(end, 0), messages.count)
        guard clampedEnd > 0, countLimit > 0 else { return ([], clampedEnd) }
        let encoder = JSONEncoder()
        var startIndex = clampedEnd
        var byteCount = 0
        var index = clampedEnd - 1
        while index >= 0 {
            let size = (try? encoder.encode(messages[index]))?.count ?? 0
            let takenSoFar = clampedEnd - startIndex
            // Always accept the newest message; afterwards stop once either
            // budget would be exceeded so the frame stays under the relay cap.
            if takenSoFar > 0,
               takenSoFar >= countLimit
                || byteCount + size > Self.mobileMessagePageByteBudget {
                break
            }
            byteCount += size
            startIndex = index
            index -= 1
        }
        return (Array(messages[startIndex ..< clampedEnd]), startIndex)
    }

    /// Single-entry cache of a disk-loaded session's full message list. Mobile
    /// pages one thread at a time, so caching just the most recent one lets the

    /// Resolve the full, cleaned message list for a session — from live stream
    /// state when available, otherwise from disk (cached). `nil` only when the
    /// session genuinely can't be located.
    func fullMobileMessages(for resolvedID: String) async -> [ChatMessage]? {
        if let state = sessionStates[resolvedID] {
            return messagesWithPlanDecisions(
                cleanLoadedMessages(state.messages),
                summaries: state.planDecisionSummaries
            )
        }
        // Non-active session: the in-memory sidecar is absent, so pull the
        // persisted decisions from the thread store.
        let summaries = threadStore.loadPlanDecisions(sessionId: resolvedID)
        if let cache = mobileFullMessageCache, cache.sessionID == resolvedID {
            return messagesWithPlanDecisions(cache.messages, summaries: summaries)
        }
        guard let summary = allSessionSummaries.first(where: { $0.id == resolvedID }),
              let project = projects.first(where: { $0.id == summary.projectId }),
              let full = await persistence.loadFullSession(summary: summary, cwd: project.path)
        else {
            return nil
        }
        let cleaned = cleanLoadedMessages(full.messages)
        mobileFullMessageCache = (resolvedID, cleaned)
        return messagesWithPlanDecisions(cleaned, summaries: summaries)
    }

    /// Bake persisted plan decisions into `ExitPlanMode` tool results before
    /// messages are sent to mobile. Once a plan resolves, the CLI overwrites the
    /// tool result with its own follow-up text ("User has approved your plan…"),
    /// which the desktop UI sidesteps with the `planDecisionSummaries` sidecar.
    /// Mobile has no such sidecar — it reads `toolCall.result` directly — so the
    /// user-decision summary must be written onto the wire result, otherwise the
    /// mobile plan banner reappears after a decision.
    func messagesWithPlanDecisions(
        _ messages: [ChatMessage],
        summaries: [String: String]
    ) -> [ChatMessage] {
        guard !summaries.isEmpty else { return messages }
        return messages.map { messageWithPlanDecisions($0, summaries: summaries) }
    }

    func messageWithPlanDecisions(
        _ message: ChatMessage,
        summaries: [String: String]
    ) -> ChatMessage {
        guard !summaries.isEmpty else { return message }
        var result = message
        for block in message.blocks {
            guard let toolCall = block.toolCall,
                  PlanLogic.isExitPlanMode(toolCall),
                  let summary = summaries[toolCall.id] else { continue }
            // Skip when the result is already the user-decision string.
            if toolCall.result.map(PlanDecisionAction.isUserDecisionResult) != true {
                result.setToolResult(id: toolCall.id, result: summary, isError: false)
            }
        }
        return result
    }

    /// Build the active-session payload for a snapshot: only the most recent
    /// page of messages, plus whether older messages remain. Mobile pages the
    /// rest in via `load_more_messages` so a snapshot never carries a whole
    /// (potentially multi-MB) thread history in one frame.
    func mobileActiveSessionPayload(
        for requestedID: String?
    ) async -> (id: String?, messages: [ChatMessage]?, hasMore: Bool) {
        guard let requestedID else { return (nil, nil, false) }
        let resolvedID = resolveCurrentSessionId(requestedID)
        guard let all = await fullMobileMessages(for: resolvedID) else {
            return (nil, nil, false)
        }
        let (page, startIndex) = mobileMessagePage(
            from: all,
            endingAt: all.count,
            countLimit: Self.mobileMessagePageSize
        )
        return (resolvedID, page, startIndex > 0)
    }

    /// Reply to a mobile `load_more_messages` request with the page of messages
    /// immediately older than `beforeMessageID`.
    func handleMobileLoadMoreMessages(
        _ request: LoadMoreMessagesRequestPayload,
        fromHex: String
    ) async {
        let resolvedID = resolveCurrentSessionId(request.sessionID)
        let all = await fullMobileMessages(for: resolvedID) ?? []
        guard let anchorIndex = all.firstIndex(where: { $0.id == request.beforeMessageID }) else {
            // The anchor is gone (thread changed, or never loaded). Stop paging.
            await MobileSyncService.shared.send(
                .moreMessages(MoreMessagesPayload(
                    clientRequestID: request.clientRequestID,
                    sessionID: request.sessionID,
                    messages: [],
                    hasMore: false
                )),
                toHex: fromHex
            )
            return
        }
        let limit = max(1, request.limit)
        let (page, startIndex) = mobileMessagePage(
            from: all,
            endingAt: anchorIndex,
            countLimit: limit
        )
        await MobileSyncService.shared.send(
            .moreMessages(MoreMessagesPayload(
                clientRequestID: request.clientRequestID,
                sessionID: request.sessionID,
                messages: page,
                hasMore: startIndex > 0
            )),
            toHex: fromHex
        )
    }

    /// Builds the change overview for the mobile "View Changes" sheet: every
    /// file edited in the thread session plus the project's uncommitted git
    /// changes. Replies with a `threadChangesResult`.
    func handleMobileThreadChangesRequest(
        _ request: ThreadChangesRequestPayload,
        fromHex hex: String
    ) async {
        let resolvedID = resolveCurrentSessionId(request.sessionID)

        // This Turn: every file edited in the thread session (SwiftData history).
        let editSummaries = threadStore.fetchFileEdits(sessionId: resolvedID).map { $0.toSummary() }
        let unboundedEdits = await withTaskGroup(of: (Int, SyncFileEdit).self) { group in
            for (index, summary) in editSummaries.enumerated() {
                group.addTask {
                    let fullFileDiff = await Self.mobileFullFileDiff(
                        path: summary.path,
                        hunks: summary.hunks,
                        originalContent: summary.originalContent
                    )
                    return (index, SyncFileEdit(
                        path: summary.path,
                        name: summary.name,
                        containsWrite: summary.containsWrite,
                        hunks: summary.hunks.map {
                            SyncEditHunk(oldString: $0.oldString, newString: $0.newString)
                        },
                        fullFileDiff: fullFileDiff,
                        originalContent: summary.originalContent,
                        modifiedContent: summary.modifiedContent
                    ))
                }
            }

            var ordered = Array<SyncFileEdit?>(repeating: nil, count: editSummaries.count)
            for await (index, edit) in group {
                ordered[index] = edit
            }
            return ordered.compactMap(\.self)
        }
        // The relay caps each encrypted envelope at 10 MiB. A long thread of
        // large-file edits can easily exceed that once every file's full
        // before/after snapshot is included, and the oversize send is dropped
        // silently — leaving the mobile sheet stuck on "Loading changes…".
        // Drop snapshots that would push the reply past a conservative budget;
        // mobile falls back to `fullFileDiff` / `hunks` when snapshots are nil.
        let turnEdits = Self.applySnapshotBudget(to: unboundedEdits)

        func reply(ok: Bool, error: String?, uncommitted: [SyncGitChange]) async {
            await MobileSyncService.shared.send(
                .threadChangesResult(ThreadChangesResultPayload(
                    clientRequestID: request.clientRequestID,
                    sessionID: request.sessionID,
                    ok: ok,
                    errorMessage: error,
                    turnEdits: turnEdits,
                    uncommitted: uncommitted
                )),
                toHex: hex
            )
        }

        // Uncommitted: the session's project working tree.
        let projectPath = allSessionSummaries
            .first(where: { $0.id == resolvedID })
            .flatMap { summary in projects.first(where: { $0.id == summary.projectId })?.path }

        guard let projectPath, !projectPath.isEmpty else {
            await reply(ok: false, error: "This thread has no associated project folder.", uncommitted: [])
            return
        }

        guard let gitChanges = await GitHelper.uncommittedChanges(at: projectPath) else {
            await reply(ok: false, error: "This project is not a git repository.", uncommitted: [])
            return
        }

        let uncommitted = gitChanges.map { change -> SyncGitChange in
            let kind: SyncGitChangeKind = switch change.kind {
            case .staged: .staged
            case .unstaged: .unstaged
            case .untracked: .untracked
            }
            return SyncGitChange(
                displayPath: change.displayPath,
                statusChar: change.statusChar,
                kind: kind,
                unifiedDiff: change.unifiedDiff,
                truncated: change.truncated
            )
        }
        await reply(ok: true, error: nil, uncommitted: uncommitted)
    }

    func handleMobileRemoteFileRequest(
        _ request: RemoteFileRequestPayload,
        fromHex hex: String
    ) async {
        let path = URL(fileURLWithPath: request.path).standardizedFileURL.path
        let name = URL(fileURLWithPath: path).lastPathComponent

        func reply(ok: Bool, error: String?, content: String? = nil, truncated: Bool = false) async {
            await MobileSyncService.shared.send(
                .remoteFileResult(RemoteFileResultPayload(
                    clientRequestID: request.clientRequestID,
                    path: path,
                    name: name.isEmpty ? path : name,
                    line: request.line,
                    ok: ok,
                    errorMessage: error,
                    content: content,
                    truncated: truncated
                )),
                toHex: hex
            )
        }

        guard Self.isPath(path, underAnyProject: projects.map(\.path)) else {
            await reply(ok: false, error: "This file is outside your RxCode projects.")
            return
        }

        do {
            let result = try await Task.detached {
                try Self.readMobilePreviewFile(path: path)
            }.value
            await reply(ok: true, error: nil, content: result.content, truncated: result.truncated)
        } catch let error as MobileRemoteFileReadError {
            await reply(ok: false, error: error.localizedDescription)
        } catch {
            await reply(ok: false, error: "Read failed: \(error.localizedDescription)")
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
                Task { @MainActor in self?.reindexProgress = (done, total) }
            }
        )
        reindexProgress = nil
    }

}

