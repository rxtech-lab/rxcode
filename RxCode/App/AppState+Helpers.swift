import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Marketplace

    func loadMarketplace(forceRefresh: Bool = false) async {
        marketplaceLoading = true
        marketplaceSourceError = nil
        defer { marketplaceLoading = false }

        async let catalog = marketplace.fetchCatalog(forceRefresh: forceRefresh)
        async let installed = marketplace.installedPluginNames()

        let fetchedCatalog = await catalog
        let installedNames = await installed
        await marketplace.importInstalledPlugins(catalog: fetchedCatalog, installedNames: installedNames)

        marketplaceCatalog = fetchedCatalog
        marketplaceInstalledNames = installedNames
        marketplaceCustomSources = await marketplace.customSources()
    }

    func installMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        marketplacePluginStates[plugin.id] = .installing
        do {
            try await marketplace.installPlugin(plugin)
            marketplacePluginStates[plugin.id] = .installed
            marketplaceInstalledNames.insert(plugin.name)
        } catch {
            marketplacePluginStates[plugin.id] = .failed(error.localizedDescription)
            logger.error("Failed to install plugin \(plugin.name): \(error.localizedDescription)")
        }
    }

    func uninstallMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        do {
            try await marketplace.uninstallPlugin(plugin)
            marketplaceInstalledNames.remove(plugin.name)
            marketplacePluginStates[plugin.id] = .notInstalled
        } catch {
            logger.error("Failed to uninstall plugin \(plugin.name): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func addMarketplaceGitSource(url: String, ref: String?) async -> Bool {
        marketplaceSourceError = nil
        do {
            _ = try await marketplace.addCustomGitSource(url: url, ref: ref)
            marketplaceCustomSources = await marketplace.customSources()
            await loadMarketplace(forceRefresh: true)
            return true
        } catch {
            marketplaceSourceError = error.localizedDescription
            logger.error("Failed to add marketplace Git source: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeMarketplaceGitSource(_ source: MarketplaceCustomSource) async -> Bool {
        marketplaceSourceError = nil
        do {
            try await marketplace.removeCustomGitSource(source)
            marketplaceCustomSources = await marketplace.customSources()
            await loadMarketplace(forceRefresh: true)
            return true
        } catch {
            marketplaceSourceError = error.localizedDescription
            logger.error("Failed to remove marketplace Git source: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Attachment Management

    func addAttachment(_ attachment: Attachment, in window: WindowState) {
        window.attachments.append(attachment)
    }

    func removeAttachment(_ id: UUID, in window: WindowState) {
        window.removeAttachment(id)
    }

    func buildPromptWithAttachments(_ text: String, attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let attachmentLines = attachments.map(\.promptContext).joined(separator: "\n")
        let userText = text.isEmpty ? "See attached files" : text
        return "\(attachmentLines)\n\n\(userText)"
    }

    // MARK: - Private Helpers

    /// Extract the last response time from the message list. Based on the last assistant message; falls back to the last message, then current time.
    func lastResponseDate(from messages: [ChatMessage]) -> Date {
        messages.last(where: { $0.role == .assistant })?.timestamp
            ?? messages.last?.timestamp
            ?? Date()
    }

    func cleanLoadedMessages(_ raw: [ChatMessage]) -> [ChatMessage] {
        raw.compactMap { message in
            var msg = message
            msg.isStreaming = false
            if msg.blocks.isEmpty, msg.role == .assistant { return nil }
            return msg
        }
    }


    /// Build the routing summary for `persistence.loadFullSession`. Falls back
    /// to a synthesized `.cliBacked` summary when the session hasn't been
    /// indexed yet (e.g. brand-new session whose `.result` arrived before the
    /// summary list refresh).
    func summaryFor(sessionId: String, projectId: UUID) -> ChatSession.Summary {
        let fallbackProvider = defaultModelSelection(for: projects.first { $0.id == projectId }).provider
        return allSessionSummaries.first(where: { $0.id == sessionId })
            ?? ChatSession.Summary(
                id: sessionId, projectId: projectId, title: "",
                createdAt: Date(), updatedAt: Date(), isPinned: false,
                agentProvider: sessionStates[sessionId]?.agentProvider ?? fallbackProvider,
                origin: (sessionStates[sessionId]?.agentProvider ?? fallbackProvider).defaultSessionOrigin
            )
    }

    /// Reload messages from the CLI's jsonl on disk and fill any blocks the
    /// live stream may have missed (e.g. ownership-transfer races, observation
    /// re-subscribe gaps). Fired off as a detached task so the stream loop is
    /// not delayed by the mmap parse.
    ///
    /// Replacement is gated on disk having strictly more block content than
    /// memory, so the common no-drift case produces no UI churn. Before the
    /// parse, the file size is compared against the last seen size — if the
    /// jsonl hasn't grown, the parse is skipped entirely.
    func reconcileFromDisk(sessionId: String, projectId: UUID, cwd: String) {
        let summary = summaryFor(sessionId: sessionId, projectId: projectId)
        let lastSize = lastReconciledJsonlSize[sessionId]

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let resolvedURL = await self.cliStore.resolveExistingJsonlURL(sid: sessionId, cwd: cwd)
            let fallbackURL = await self.cliStore.directory(forCwd: cwd).appendingPathComponent("\(sessionId).jsonl")
            let url = resolvedURL ?? fallbackURL
            let currentSize: UInt64? = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int)
                .flatMap(UInt64.init(exactly:))
            if let lastSize, let currentSize, currentSize <= lastSize { return }

            guard let full = await self.persistence.loadFullSession(summary: summary, cwd: cwd) else { return }
            let cleaned = await self.cleanLoadedMessages(full.messages)
            await MainActor.run {
                guard var state = self.sessionStates[sessionId], !state.isStreaming else { return }
                if let currentSize { self.lastReconciledJsonlSize[sessionId] = currentSize }
                let memBlocks = state.messages.reduce(0) { $0 + $1.blocks.count }
                let diskBlocks = cleaned.reduce(0) { $0 + $1.blocks.count }
                guard diskBlocks > memBlocks else { return }
                self.logger.info("[Reconcile] sid=\(sessionId, privacy: .public) memBlocks=\(memBlocks) diskBlocks=\(diskBlocks) — applied")
                state.messages = cleaned
                self.sessionStates[sessionId] = state
            }
        }
    }

    /// Load messages in the background and inject without blocking the main thread.
    /// Does not overwrite if currently streaming or if messages already exist.
    /// `cwd` is needed so we can route to the CLI's jsonl when origin is `.cliBacked`.
    func loadMessagesInBackground(projectId: UUID, sessionId: String, cwd: String) {
        // Snapshot the summary while we're on MainActor so the detached task
        // can route by origin without awaiting back to us first.
        let summary = summaryFor(sessionId: sessionId, projectId: projectId)
        logger.info("[LoadMessages] start sid=\(sessionId, privacy: .public) origin=\(String(describing: summary.origin), privacy: .public) cwd=\(cwd, privacy: .public)")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let full = await self.persistence.loadFullSession(summary: summary, cwd: cwd)
            let cleaned: [ChatMessage]
            if let full {
                cleaned = await self.cleanLoadedMessages(full.messages)
            } else {
                cleaned = []
            }
            await MainActor.run {
                let rawCount = full?.messages.count ?? -1
                self.logger.info("[LoadMessages] loaded sid=\(sessionId, privacy: .public) rawMessages=\(rawCount) cleaned=\(cleaned.count)")
                guard var state = self.sessionStates[sessionId] else {
                    self.logger.error("[LoadMessages] dropped — no sessionState sid=\(sessionId, privacy: .public)")
                    return
                }
                // Always clear the loading flag, even if we bail out — otherwise the UI
                // would stay faded out forever on the failure / skip paths.
                state.isLoadingFromDisk = false
                defer { self.sessionStates[sessionId] = state }
                guard let full else {
                    self.logger.error("[LoadMessages] no session returned by persistence sid=\(sessionId, privacy: .public) origin=\(String(describing: summary.origin), privacy: .public)")
                    return
                }
                guard !state.isStreaming, state.messages.isEmpty else {
                    self.logger.info("[LoadMessages] skipped apply sid=\(sessionId, privacy: .public) isStreaming=\(state.isStreaming) existingMessages=\(state.messages.count)")
                    return
                }
                state.messages = cleaned
                state.planDecisionSummaries = self.threadStore.loadPlanDecisions(sessionId: sessionId)
                if state.model == nil { state.model = full.model }
                if state.effort == nil { state.effort = full.effort }
                if state.permissionMode == nil { state.permissionMode = full.permissionMode }
                self.logger.info("[LoadMessages] applied sid=\(sessionId, privacy: .public) messages=\(state.messages.count) planDecisions=\(state.planDecisionSummaries.count)")
            }
        }
    }

    func saveCurrentSession(in window: WindowState) async {
        guard let project = window.selectedProject,
              let sessionId = window.currentSessionId else { return }
        await saveSession(
            sessionId: sessionId,
            projectId: project.id,
            messages: stateForSession(sessionId).messages
        )
    }

    func saveSession(sessionId: String, projectId: UUID, messages: [ChatMessage]) async {
        guard !messages.isEmpty else { return }

        // Preserve the existing title (which may have been renamed by the user or
        // generated by the LLM). Fall back to the default placeholder; the LLM
        // title generator replaces it once the first assistant reply arrives.
        let summary = allSessionSummaries.first(where: { $0.id == sessionId })
        let title: String
        if let existing = summary, !existing.title.isEmpty {
            title = existing.title
        } else {
            title = ChatSession.defaultTitle
        }

        let sessionModel = sessionStates[sessionId]?.model
            ?? summary?.model
        let sessionAgentProvider = sessionStates[sessionId]?.agentProvider
            ?? summary?.agentProvider
            ?? selectedAgentProvider
        let sessionEffort = sessionStates[sessionId]?.effort
            ?? summary?.effort
        let sessionPermissionMode = sessionStates[sessionId]?.permissionMode
            ?? summary?.permissionMode
        let origin = summary?.origin
            ?? sessionAgentProvider.defaultSessionOrigin
        let session = ChatSession(
            id: sessionId,
            projectId: projectId,
            title: title,
            messages: messages,
            updatedAt: lastResponseDate(from: messages),
            isPinned: summary?.isPinned ?? false,
            agentProvider: sessionAgentProvider,
            model: sessionModel,
            effort: sessionEffort,
            permissionMode: sessionPermissionMode,
            origin: origin,
            worktreePath: summary?.worktreePath,
            worktreeBranch: summary?.worktreeBranch,
            isArchived: summary?.isArchived ?? false,
            archivedAt: summary?.archivedAt
        )

        do {
            try await persistence.saveSession(session)
        } catch {
            logger.error("Failed to save session \(sessionId): \(error.localizedDescription)")
        }

        // Update allSessionSummaries — skipped while streaming (updated only once after completion)
        let isCurrentlyStreaming = sessionStates[sessionId]?.isStreaming ?? false
        if !isCurrentlyStreaming {
            let summary = session.summary
            withAnimation(nil) {
                while allSessionSummaries.filter({ $0.id == sessionId }).count > 1,
                      let lastIdx = allSessionSummaries.lastIndex(where: { $0.id == sessionId })
                {
                    allSessionSummaries.remove(at: lastIdx)
                }
                if let index = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
                    allSessionSummaries[index] = summary
                } else {
                    allSessionSummaries.insert(summary, at: 0)
                }
            }
            threadStore.upsert(summary)

            // Update the on-device semantic index. Skipped while streaming so
            // we only embed a thread once it has settled.
            let snapshot = session
            Task.detached(priority: .utility) { [searchService] in
                await searchService.indexThread(snapshot)
            }
        }

        // Update the project's lastSessionId
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].lastSessionId = sessionId
            do {
                try await persistence.saveProjects(projects)
            } catch {
                logger.error("Failed to save projects: \(error.localizedDescription)")
            }
        }
    }

    func saveDraft(in window: WindowState) {
        let key = draftKey(for: window)
        let trimmed = window.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { window.draftTexts.removeValue(forKey: key) }
        else { window.draftTexts[key] = window.inputText }
    }

    func saveQueue(in window: WindowState) {
        let key = queueKey(for: window)
        if window.messageQueue.isEmpty { window.draftQueues.removeValue(forKey: key) }
        else { window.draftQueues[key] = window.messageQueue }
    }

    /// Persistence key used for both the in-memory `draftQueues` mirror and the
    /// SwiftData `QueuedMessageRecord.sessionKey` column.
    func queueKey(for window: WindowState) -> String {
        draftKey(for: window)
    }

    func draftKey(for window: WindowState) -> String {
        window.currentSessionId ?? newDraftKey(for: window)
    }

    func newDraftKey(for window: WindowState) -> String {
        guard let projectId = window.selectedProject?.id else { return "new" }
        return "new:\(projectId.uuidString)"
    }

    func renameDraftState(from oldKey: String, to newKey: String, in window: WindowState) {
        guard oldKey != newKey else { return }

        if let text = window.draftTexts.removeValue(forKey: oldKey),
           window.draftTexts[newKey] == nil {
            window.draftTexts[newKey] = text
        }

        guard let queue = window.draftQueues.removeValue(forKey: oldKey) else { return }
        if var existing = window.draftQueues[newKey] {
            existing.append(contentsOf: queue)
            window.draftQueues[newKey] = existing
        } else {
            window.draftQueues[newKey] = queue
        }
    }

    // MARK: - Message Queue (persisted)

    func enqueueMessage(text: String, attachments: [Attachment], in window: WindowState) {
        let message = QueuedMessage(text: text, attachments: attachments)
        window.messageQueue.append(message)
        let key = queueKey(for: window)
        window.draftQueues[key] = window.messageQueue
        threadStore.appendQueued(sessionKey: key, message: message)
        broadcastMobileSessionStatus(sessionID: key)
    }

    func removeQueuedMessage(id: UUID, in window: WindowState) {
        window.dequeueMessage(id: id)
        saveQueue(in: window)
        threadStore.removeQueued(id: id)
        broadcastMobileSessionStatus(sessionID: queueKey(for: window))
    }

    /// Pops the head of the queue (the auto-flush path used when a stream ends)
    /// and removes the persisted row.
    func dequeueNextForFlush(in window: WindowState) -> QueuedMessage? {
        guard let next = window.dequeueNext() else { return nil }
        saveQueue(in: window)
        threadStore.removeQueued(id: next.id)
        broadcastMobileSessionStatus(sessionID: queueKey(for: window))
        return next
    }

    /// Cancels any in-flight stream for the current session, removes the chosen
    /// queued message, and sends it as the next user turn.
    func sendQueuedNow(id: UUID, in window: WindowState) async {
        guard let target = window.messageQueue.first(where: { $0.id == id }) else { return }
        // Take a snapshot of remaining queue items so we can restore them after
        // `cancelStreaming` clobbers `window.inputText`/`window.attachments`.
        let remaining = window.messageQueue.filter { $0.id != id }
        let draftText = window.inputText
        let draftAttachments = window.attachments
        let shouldRestoreDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty

        // Clear the queue from memory + disk first, so the cancellation path
        // doesn't see the queued item we're about to send.
        let key = queueKey(for: window)
        window.messageQueue.removeAll()
        window.draftQueues.removeValue(forKey: key)
        threadStore.clearQueue(sessionKey: key)

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        // Restore the remaining items into memory + disk.
        for msg in remaining {
            window.messageQueue.append(msg)
            threadStore.appendQueued(sessionKey: key, message: msg)
        }
        if remaining.isEmpty {
            window.draftQueues.removeValue(forKey: key)
        } else {
            window.draftQueues[key] = window.messageQueue
        }

        window.inputText = target.text
        window.attachments = target.attachments
        await send(in: window)
        if shouldRestoreDraft {
            window.inputText = draftText
            window.attachments = draftAttachments
        }
        broadcastMobileSessionStatus(sessionID: key)
    }

    /// Concatenates every queued message (texts joined with a blank line,
    /// attachments merged in order), cancels any in-flight stream, clears the
    /// queue, then sends the combined message as a single user turn.
    func sendAllQueuedAsOne(in window: WindowState) async {
        guard !window.messageQueue.isEmpty else { return }
        let snapshot = window.messageQueue
        let draftText = window.inputText
        let draftAttachments = window.attachments
        let shouldRestoreDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty

        let key = queueKey(for: window)
        window.messageQueue.removeAll()
        window.draftQueues.removeValue(forKey: key)
        threadStore.clearQueue(sessionKey: key)

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        let combinedText = snapshot
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let combinedAttachments = snapshot.flatMap(\.attachments)

        window.inputText = combinedText
        window.attachments = combinedAttachments
        await send(in: window)
        if shouldRestoreDraft {
            window.inputText = draftText
            window.attachments = draftAttachments
        }
        broadcastMobileSessionStatus(sessionID: key)
    }

    /// Sends the next queued message for a background session (one the window is not currently displaying).
    /// Foreground session queues are handled by InputBarView via the isStreaming onChange handler.
    func processBackgroundQueue(
        for sessionKey: String,
        projectId: UUID,
        cwd: String,
        in window: WindowState
    ) async {
        guard sessionStates[sessionKey]?.isStreaming != true else { return }
        guard var queue = window.draftQueues[sessionKey], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if queue.isEmpty { window.draftQueues.removeValue(forKey: sessionKey) }
        else { window.draftQueues[sessionKey] = queue }
        threadStore.removeQueued(id: next.id)

        let (resolvedAttachments, tempFilePaths) = AttachmentFactory.resolvingClipboardImages(next.attachments)
        let prompt = buildPromptWithAttachments(next.text, attachments: resolvedAttachments)
        let displayText = next.text
        let streamId = UUID()

        updateState(sessionKey) { state in
            state.messages.append(ChatMessage(role: .user, content: displayText, attachments: resolvedAttachments))
            state.inFlightUserAttachments = resolvedAttachments
            state.isStreaming = true
            state.hasUncheckedCompletion = false
            state.activeStreamId = streamId
            state.streamingStartDate = Date()
            state.currentTurnOutputTokensByMessage.removeAll(keepingCapacity: true)
            state.currentTurnOutputTokensUnkeyed = 0
        }

        let currentPermissionMode = sessionStates[sessionKey]?.permissionMode ?? permissionMode
        let projectSelection = defaultModelSelection(for: projects.first { $0.id == projectId })
        let agentProvider = sessionStates[sessionKey]?.agentProvider ?? projectSelection.provider
        var hookSettingsPath: String?
        if agentProvider == .claudeCode, !currentPermissionMode.skipsHookPipeline {
            do { hookSettingsPath = try await permission.writeHookSettingsFile() }
            catch { logger.error("Failed to write hook settings for background queue: \(error.localizedDescription)") }
        }

        await permission.registerSession(sid: sessionKey, projectKey: cwd, mode: currentPermissionMode)

        let model = sessionStates[sessionKey]?.model ?? projectSelection.model
        let effort = sessionStates[sessionKey]?.effort ?? (selectedEffort == "auto" ? nil : selectedEffort)
        let task = Task { [weak self, window] in
            guard let self else { return }
            await self.processStream(
                streamId: streamId,
                prompt: prompt,
                cwd: cwd,
                cliSessionId: sessionKey,
                internalSessionKey: sessionKey,
                agentProvider: agentProvider,
                model: model,
                effort: effort,
                hookSettingsPath: hookSettingsPath,
                permissionMode: currentPermissionMode,
                projectId: projectId,
                window: window
            )
            for path in tempFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        sessionStates[sessionKey]?.streamTask = task
    }

    func handleError(_ error: Error, in window: WindowState) {
        logger.error("AppState error: \(error.localizedDescription)")
        addErrorMessage(error.localizedDescription, in: window)
    }

    func addErrorMessage(_ text: String, in window: WindowState) {
        let key = window.currentSessionId ?? window.newSessionKey
        let msg = ChatMessage(role: .assistant, content: text, isError: true)
        updateState(key) { $0.messages.append(msg) }
    }

    // MARK: - Claude Settings Reader

    nonisolated static func readPermissionModeFromSettings() -> PermissionMode {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let permissions = json["permissions"] as? [String: Any],
           let mode = permissions["defaultMode"] as? String,
           let parsed = PermissionMode(rawValue: mode)
        {
            return parsed
        }
        if let saved = UserDefaults.standard.string(forKey: "selectedPermissionMode"),
           let parsed = PermissionMode(rawValue: saved)
        {
            return parsed
        }
        return .default
    }
}
