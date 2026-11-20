import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Mobile Sync Bridge

extension AppState {
    /// Make this workspace the single owner of mobile sync: register the inbound
    /// request observers and supply the desktop-side resolvers. Called by
    /// `WorkspaceManager` when this workspace becomes frontmost. Idempotent.
    func bindMobileSyncOwnership() {
        guard mobileSyncObservers.isEmpty else { return }
        setupMobileSyncBridge()

        // Supply MobileSyncService with desktop-side context for the mobile
        // job Live Activity and home-screen widget pushes.
        MobileSyncService.shared.projectNameResolver = { [weak self] id in
            self?.projects.first { $0.id == id }?.name
        }
        MobileSyncService.shared.usageCardsProvider = { [weak self] in
            guard let self else { return [] }
            // Keep encrypted APNs envelopes comfortably below the size limit.
            return self.usageDashboard.cards.filter(\.showInWidget).prefix(3).compactMap { card in
                guard let snapshot = self.usageDashboard.snapshot(for: card) else { return nil }
                let metric = snapshot.metrics.first { card.includesMetric($0.id) }
                return UsageWidgetCardPayload(id: card.id.uuidString, title: String(snapshot.title.prefix(60)),
                    value: String((metric.map { "\($0.title): \($0.formattedValue)" } ?? "No data").prefix(100)),
                    detail: String((snapshot.error ?? snapshot.period).prefix(100)), fetchedAt: snapshot.fetchedAt.timeIntervalSince1970)
            }
        }
        MobileSyncService.shared.usageSnapshotProvider = { [weak self] in
            (
                cc: self?.latestRateLimitUsage?.fiveHourPercent,
                ccWeekly: self?.latestRateLimitUsage?.sevenDayPercent,
                codex: self?.latestCodexRateLimitUsage?.fiveHourPercent,
                codexWeekly: self?.latestCodexRateLimitUsage?.sevenDayPercent
            )
        }
    }

    /// Relinquish mobile-sync ownership: remove this workspace's inbound request
    /// observers so it stops responding to mobile requests once another
    /// workspace becomes frontmost.
    func unbindMobileSyncOwnership() {
        let center = NotificationCenter.default
        mobileSyncObservers.forEach { center.removeObserver($0) }
        mobileSyncObservers.removeAll()
    }

    func setupMobileSyncBridge() {
        let center = NotificationCenter.default
        let snapshotObserver = center.addObserver(
            forName: .mobileSyncSnapshotRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String else { return }
            let activeSessionID = notification.userInfo?["activeSessionID"] as? String
            Task { @MainActor [weak self] in
                await self?.sendMobileSnapshot(toHex: fromHex, activeSessionID: activeSessionID)
            }
        }
        mobileSyncObservers.append(snapshotObserver)

        let settingsObserver = center.addObserver(
            forName: .mobileSyncSettingsUpdateReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let update = notification.userInfo?["payload"] as? MobileSettingsUpdatePayload
            else { return }
            Task { @MainActor [weak self] in
                self?.applyMobileSettingsUpdate(update)
                await self?.sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            }
        }
        mobileSyncObservers.append(settingsObserver)

        let userMessageObserver = center.addObserver(
            forName: .mobileSyncUserMessageReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let message = notification.userInfo?["payload"] as? UserMessagePayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileUserMessage(message, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(userMessageObserver)

        let cancelStreamObserver = center.addObserver(
            forName: .mobileSyncCancelStreamRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let cancel = notification.userInfo?["payload"] as? CancelStreamPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileCancelStream(cancel)
            }
        }
        mobileSyncObservers.append(cancelStreamObserver)

        let removeQueuedObserver = center.addObserver(
            forName: .mobileSyncRemoveQueuedRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            if let action = notification.userInfo?["payload"] as? QueueMessageActionPayload {
                Task { @MainActor [weak self] in await self?.handleMobileQueueAction(action) }
                return
            }
            guard let payload = notification.userInfo?["payload"] as? RemoveQueuedMessagePayload
            else { return }
            Task { @MainActor [weak self] in
                self?.handleMobileRemoveQueuedMessage(payload)
            }
        }
        mobileSyncObservers.append(removeQueuedObserver)

        let newSessionObserver = center.addObserver(
            forName: .mobileSyncNewSessionRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? NewSessionRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileNewSessionRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(newSessionObserver)

        let threadActionObserver = center.addObserver(
            forName: .mobileSyncThreadActionRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ThreadActionRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileThreadActionRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(threadActionObserver)

        let loadMoreObserver = center.addObserver(
            forName: .mobileSyncLoadMoreMessagesRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? LoadMoreMessagesRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileLoadMoreMessages(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(loadMoreObserver)

        let searchObserver = center.addObserver(
            forName: .mobileSyncSearchRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SearchRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSearchRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(searchObserver)

        let threadChangesObserver = center.addObserver(
            forName: .mobileSyncThreadChangesRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ThreadChangesRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileThreadChangesRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(threadChangesObserver)

        let remoteFileObserver = center.addObserver(
            forName: .mobileSyncRemoteFileRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RemoteFileRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRemoteFileRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(remoteFileObserver)

        let briefingContentObserver = center.addObserver(
            forName: .mobileSyncBriefingContentRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? BriefingContentRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileBriefingContentRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(briefingContentObserver)

        let branchOpObserver = center.addObserver(
            forName: .mobileSyncBranchOpRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? BranchOpRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileBranchOpRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(branchOpObserver)

        let folderTreeObserver = center.addObserver(
            forName: .mobileSyncFolderTreeRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? FolderTreeRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileFolderTreeRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(folderTreeObserver)

        let createProjectObserver = center.addObserver(
            forName: .mobileSyncCreateProjectRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? CreateProjectRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileCreateProjectRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(createProjectObserver)

        let deleteProjectObserver = center.addObserver(
            forName: .mobileSyncDeleteProjectRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? DeleteProjectRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileDeleteProjectRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(deleteProjectObserver)

        let runProfileMutationObserver = center.addObserver(
            forName: .mobileSyncRunProfileMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunProfileMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunProfileMutation(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runProfileMutationObserver)

        let runProfileRunObserver = center.addObserver(
            forName: .mobileSyncRunProfileRunRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunProfileRunRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunProfileRun(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runProfileRunObserver)

        let runProfileStopObserver = center.addObserver(
            forName: .mobileSyncRunProfileStopRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunProfileStopRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunProfileStop(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runProfileStopObserver)

        let runnableDetectObserver = center.addObserver(
            forName: .mobileSyncRunnableDetectRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunnableDetectRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunnableDetectRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runnableDetectObserver)

        let questionAnswerObserver = center.addObserver(
            forName: .mobileSyncQuestionAnswerReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? QuestionAnswerPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileQuestionAnswer(payload)
            }
        }
        mobileSyncObservers.append(questionAnswerObserver)

        let planDecisionObserver = center.addObserver(
            forName: .mobileSyncPlanDecisionReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? PlanDecisionPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobilePlanDecision(payload)
            }
        }
        mobileSyncObservers.append(planDecisionObserver)

        let confirmationDecisionObserver = center.addObserver(
            forName: .mobileSyncConfirmationDecisionReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? ConfirmationDecisionPayload,
                  let id = UUID(uuidString: payload.id)
            else { return }
            Task { @MainActor [weak self] in
                self?.resolveAgentConfirmation(id: id, confirmed: payload.confirmed)
            }
        }
        mobileSyncObservers.append(confirmationDecisionObserver)

        let skillCatalogObserver = center.addObserver(
            forName: .mobileSyncSkillCatalogRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SkillCatalogRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSkillCatalogRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(skillCatalogObserver)

        let skillMutationObserver = center.addObserver(
            forName: .mobileSyncSkillMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SkillMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSkillMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(skillMutationObserver)

        let skillSourceMutationObserver = center.addObserver(
            forName: .mobileSyncSkillSourceMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SkillSourceMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSkillSourceMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(skillSourceMutationObserver)

        let acpRegistryObserver = center.addObserver(
            forName: .mobileSyncACPRegistryRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ACPRegistryRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileACPRegistryRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(acpRegistryObserver)

        let acpMutationObserver = center.addObserver(
            forName: .mobileSyncACPMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ACPMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileACPMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(acpMutationObserver)

        let mcpConfigObserver = center.addObserver(
            forName: .mobileSyncMCPConfigRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? MCPConfigRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileMCPConfigRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(mcpConfigObserver)

        let mcpMutationObserver = center.addObserver(
            forName: .mobileSyncMCPMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? MCPMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileMCPMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(mcpMutationObserver)

        let autopilotObserver = center.addObserver(
            forName: .mobileSyncAutopilotRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? AutopilotRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileAutopilotRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(autopilotObserver)

        let taskBoardObserver = center.addObserver(
            forName: .mobileSyncTaskBoardRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? TaskBoardRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileTaskBoardRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(taskBoardObserver)

        observeMobileSnapshotInputs()
    }

    func observeMobileSnapshotInputs() {
        withObservationTracking {
            _ = selectedAgentProvider
            _ = selectedModel
            _ = selectedACPClientId
            _ = selectedEffort
            _ = permissionMode
            _ = notificationsEnabled
            _ = focusMode
            _ = autoArchiveEnabled
            _ = archiveRetentionDays
            _ = autoPreviewSettings
            _ = branchBriefingRevision
            _ = briefingDocuments
            _ = threadSummaryRevision
            _ = ciStatusRevision
            _ = projects.count
            _ = allSessionSummaries.count
            _ = latestRateLimitUsage
            _ = latestCodexRateLimitUsage
            _ = runProfilesByProject.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleMobileSnapshotBroadcast()
                self?.observeMobileSnapshotInputs()
            }
        }
    }

    func handleMobileNewSessionRequest(_ request: NewSessionRequestPayload, fromHex: String) async {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] new thread requested for unknown project=\(request.projectID.uuidString, privacy: .public)")
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        let initialText = request.initialText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !initialText.isEmpty else {
            let sessionID = createMobilePlaceholderSession(project: project, requestID: request.clientRequestID)
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: sessionID)
            return
        }

        let window = WindowState()
        window.selectedProject = project
        // Per-thread agent config captured in the mobile new-thread sheet. These
        // session-scoped fields win over the project/global defaults in
        // `effectiveModelSelection`, so the thread runs on exactly the chosen
        // model — and starts in plan mode when requested. Carrying the config in
        // the request also removes the `settings_update`/`newSessionRequest`
        // ordering race.
        if let provider = request.selectedAgentProvider {
            window.sessionAgentProvider = provider
        }
        if let model = request.selectedModel, !model.isEmpty {
            window.sessionModel = model
        }
        if let effort = request.selectedEffort, !effort.isEmpty, effort != "auto" {
            window.sessionEffort = effort
        }
        if let mode = request.permissionMode {
            window.sessionPermissionMode = mode
        }
        window.sessionPlanMode = request.planMode ?? false
        if let pending = mobilePendingWorktrees.removeValue(forKey: project.id) {
            window.pendingWorktreePath = pending.path
            window.pendingWorktreeBranch = pending.branch
        }
        _ = await sendPrompt(initialText, displayText: initialText, in: window)
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: window.currentSessionId)
    }

    /// Apply a mobile-initiated lifecycle action (rename / archive / unarchive /
    /// delete) to an existing thread, then push a fresh snapshot back so the
    /// requesting device reconciles immediately. The action mutators each
    /// schedule their own broadcast for the remaining paired devices.
    func handleMobileThreadActionRequest(_ request: ThreadActionRequestPayload, fromHex: String) async {
        // The mobile may hold a session id the CLI has since advanced
        // (pending-→real swap, or a compaction boundary). Follow the redirect
        // chain so the action lands on the live thread.
        let sessionID = resolveCurrentSessionId(request.sessionID)
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            logger.error("[MobileSync] thread action=\(request.action.rawValue, privacy: .public) for unknown thread=\(request.sessionID, privacy: .public)")
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        logger.info("[MobileSync] applying thread action=\(request.action.rawValue, privacy: .public) thread=\(sessionID, privacy: .public)")

        let session = summary.makeSession()
        // Mobile actions aren't tied to a desktop window; a fresh WindowState
        // keeps the data-layer mutators happy without disturbing open windows.
        let window = WindowState()

        switch request.action {
        case .rename:
            let title = request.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { break }
            await renameSession(session, to: title)
        case .archive:
            await archiveSession(session, in: window)
        case .unarchive:
            await unarchiveSession(session, in: window)
        case .delete:
            await deleteSession(session, in: window)
        }

        await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
    }
}
