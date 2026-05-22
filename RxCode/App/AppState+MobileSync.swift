import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Mobile Sync Bridge

extension AppState {
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
            _ = threadSummaryRevision
            _ = projects.count
            _ = allSessionSummaries.count
            _ = latestRateLimitUsage
            _ = latestCodexRateLimitUsage
            _ = runProfilesByProject.count
        } onChange: {
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

    func handleMobileBranchOpRequest(_ request: BranchOpRequestPayload, fromHex: String) async {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: "Project not found on desktop.",
                toHex: fromHex
            )
            return
        }

        let trimmed = request.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: "Branch name is required.",
                toHex: fromHex
            )
            return
        }

        let window = WindowState()
        window.selectedProject = project

        do {
            switch request.operation {
            case .switchExisting:
                try await switchToExistingBranch(trimmed, in: window)
                updateMobilePendingWorktree(from: window, projectID: project.id)
            case .createNew:
                try await attachWorktree(branch: trimmed, in: window)
                updateMobilePendingWorktree(from: window, projectID: project.id)
            }
        } catch {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: branchOpErrorMessage(error),
                toHex: fromHex
            )
            return
        }

        await replyBranchOpResult(request: request, ok: true, errorMessage: nil, toHex: fromHex)
        scheduleMobileSnapshotBroadcast()
    }

    private func updateMobilePendingWorktree(from window: WindowState, projectID: UUID) {
        if let path = window.pendingWorktreePath,
           let branch = window.pendingWorktreeBranch
        {
            mobilePendingWorktrees[projectID] = MobilePendingWorktree(path: path, branch: branch)
        } else {
            mobilePendingWorktrees.removeValue(forKey: projectID)
        }
    }

    func replyBranchOpResult(
        request: BranchOpRequestPayload,
        ok: Bool,
        errorMessage: String?,
        toHex hex: String
    ) async {
        let result = BranchOpResultPayload(
            clientRequestID: request.clientRequestID,
            projectID: request.projectID,
            operation: request.operation,
            branch: request.branch,
            ok: ok,
            errorMessage: errorMessage
        )
        await MobileSyncService.shared.send(.branchOpResult(result), toHex: hex)
    }

    func branchOpErrorMessage(_ error: Error) -> String {
        if let werr = error as? GitWorktreeService.WorktreeError {
            return werr.description
        }
        return error.localizedDescription
    }

    func handleMobileFolderTreeRequest(_ request: FolderTreeRequestPayload, fromHex: String) async {
        let result: FolderTreeResultPayload
        do {
            let root = try mobileFolderTreeRoot(for: request)
            result = FolderTreeResultPayload(
                clientRequestID: request.clientRequestID,
                requestedPath: request.path,
                ok: true,
                root: root
            )
        } catch {
            result = FolderTreeResultPayload(
                clientRequestID: request.clientRequestID,
                requestedPath: request.path,
                ok: false,
                errorMessage: mobileFolderErrorMessage(error)
            )
        }
        await MobileSyncService.shared.send(.folderTreeResult(result), toHex: fromHex)
    }

    func handleMobileCreateProjectRequest(_ request: CreateProjectRequestPayload, fromHex: String) async {
        let trimmedPath = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            await replyCreateProjectResult(
                requestID: request.clientRequestID,
                ok: false,
                project: nil,
                errorMessage: "Folder path is required.",
                toHex: fromHex
            )
            return
        }

        let url = URL(fileURLWithPath: trimmedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            await replyCreateProjectResult(
                requestID: request.clientRequestID,
                ok: false,
                project: nil,
                errorMessage: "Folder does not exist on the desktop.",
                toHex: fromHex
            )
            return
        }

        if projects.first(where: { $0.path == url.path }) == nil {
            let isGitRepo = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            let gitHubRepo = isGitRepo ? detectGitHubOwnerRepo(at: url.path) : nil
            await addProject(name: url.lastPathComponent, path: url.path, gitHubRepo: gitHubRepo)
        }

        guard let project = projects.first(where: { $0.path == url.path }) else {
            await replyCreateProjectResult(
                requestID: request.clientRequestID,
                ok: false,
                project: nil,
                errorMessage: "Failed to add project on the desktop.",
                toHex: fromHex
            )
            return
        }

        await replyCreateProjectResult(
            requestID: request.clientRequestID,
            ok: true,
            project: project,
            errorMessage: nil,
            toHex: fromHex
        )
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
        scheduleMobileSnapshotBroadcast()
    }

    func replyCreateProjectResult(
        requestID: UUID,
        ok: Bool,
        project: Project?,
        errorMessage: String?,
        toHex hex: String
    ) async {
        let result = CreateProjectResultPayload(
            clientRequestID: requestID,
            ok: ok,
            project: project,
            errorMessage: errorMessage
        )
        await MobileSyncService.shared.send(.createProjectResult(result), toHex: hex)
    }

    func handleMobileRunProfileMutation(
        _ request: RunProfileMutationRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling run profile mutation operation=\(request.operation.rawValue, privacy: .public) project=\(request.projectID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        guard projects.contains(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] run profile mutation rejected unknown project=\(request.projectID.uuidString, privacy: .public)")
            await replyRunProfileResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Project not found on desktop.",
                task: nil,
                toHex: fromHex
            )
            return
        }

        await ensureRunProfilesLoaded(for: request.projectID)
        var profiles = runProfiles(for: request.projectID)
        let now = Date()

        switch request.operation {
        case .upsert:
            guard var profile = request.profile else {
                logger.error("[MobileSync] run profile upsert rejected missing payload project=\(request.projectID.uuidString, privacy: .public)")
                await replyRunProfileResult(
                    requestID: request.clientRequestID,
                    projectID: request.projectID,
                    ok: false,
                    errorMessage: "Profile payload is missing.",
                    task: nil,
                    toHex: fromHex
                )
                return
            }
            profile.projectId = request.projectID
            profile.updatedAt = now
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profile.createdAt = now
                profiles.append(profile)
            }
        case .delete:
            guard let profileID = request.profileID else {
                logger.error("[MobileSync] run profile delete rejected missing profile id project=\(request.projectID.uuidString, privacy: .public)")
                await replyRunProfileResult(
                    requestID: request.clientRequestID,
                    projectID: request.projectID,
                    ok: false,
                    errorMessage: "Profile id is missing.",
                    task: nil,
                    toHex: fromHex
                )
                return
            }
            profiles.removeAll { $0.id == profileID }
        }

        setRunProfiles(profiles, for: request.projectID)
        logger.info("[MobileSync] run profile mutation applied project=\(request.projectID.uuidString, privacy: .public) count=\(profiles.count, privacy: .public)")
        await replyRunProfileResult(
            requestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            errorMessage: nil,
            task: nil,
            toHex: fromHex
        )
    }

    func handleMobileRunProfileRun(
        _ request: RunProfileRunRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling run profile run project=\(request.projectID.uuidString, privacy: .public) profile=\(request.profileID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] run profile run rejected unknown project=\(request.projectID.uuidString, privacy: .public)")
            await replyRunProfileResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Project not found on desktop.",
                task: nil,
                toHex: fromHex
            )
            return
        }

        await ensureRunProfilesLoaded(for: request.projectID)
        guard let profile = runProfiles(for: request.projectID).first(where: { $0.id == request.profileID }) else {
            logger.error("[MobileSync] run profile run rejected missing profile=\(request.profileID.uuidString, privacy: .public) project=\(request.projectID.uuidString, privacy: .public) knownProfiles=\(self.runProfiles(for: request.projectID).count, privacy: .public)")
            await replyRunProfileResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Run profile not found on desktop.",
                task: nil,
                toHex: fromHex
            )
            return
        }

        let task = runService.start(profile: profile, project: project)
        logger.info("[MobileSync] run profile started task=\(task.id.uuidString, privacy: .public) profile=\(profile.name, privacy: .public) project=\(project.id.uuidString, privacy: .public)")
        await replyRunProfileResult(
            requestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            errorMessage: nil,
            task: mobileRunTaskSnapshot(task),
            toHex: fromHex
        )
    }

    func handleMobileRunProfileStop(
        _ request: RunProfileStopRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling run profile stop task=\(request.taskID?.uuidString ?? "<nil>", privacy: .public) project=\(request.projectID?.uuidString ?? "<nil>", privacy: .public) profile=\(request.profileID?.uuidString ?? "<nil>", privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        let stoppedTask: RunTask?
        if let taskID = request.taskID {
            stoppedTask = runService.task(id: taskID)
            runService.stop(taskId: taskID)
        } else if let projectID = request.projectID, let profileID = request.profileID {
            stoppedTask = runService.activeTasks.first {
                $0.project.id == projectID && $0.profile.id == profileID
            }
            if let stoppedTask {
                runService.stop(taskId: stoppedTask.id)
            }
        } else {
            stoppedTask = nil
        }

        await replyRunProfileResult(
            requestID: request.clientRequestID,
            projectID: request.projectID ?? stoppedTask?.project.id ?? UUID(),
            ok: stoppedTask != nil,
            errorMessage: stoppedTask == nil ? "No matching running task was found." : nil,
            task: stoppedTask.map(mobileRunTaskSnapshot),
            toHex: fromHex
        )
    }

    func replyRunProfileResult(
        requestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String?,
        task: MobileRunTaskSnapshot?,
        toHex hex: String
    ) async {
        await ensureRunProfilesLoaded(for: projectID)
        logger.info("[MobileSync] replying run profile result ok=\(ok, privacy: .public) project=\(projectID.uuidString, privacy: .public) profiles=\(self.runProfiles(for: projectID).count, privacy: .public) task=\(task?.taskId.uuidString ?? "<nil>", privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public) error=\(errorMessage ?? "<nil>", privacy: .public)")
        let result = RunProfileResultPayload(
            clientRequestID: requestID,
            projectID: projectID,
            ok: ok,
            errorMessage: errorMessage,
            profiles: runProfiles(for: projectID),
            task: task
        )
        await MobileSyncService.shared.send(.runProfileResult(result), toHex: hex)
        if ok { scheduleMobileSnapshotBroadcast() }
    }

    /// Scan a project for runnable Xcode schemes, npm scripts, and Make targets
    /// on behalf of a paired mobile device. Detection logic lives entirely on
    /// the desktop — mobile only displays the result.
    func handleMobileRunnableDetectRequest(
        _ request: RunnableDetectRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling runnable detection project=\(request.projectID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] runnable detection rejected unknown project=\(request.projectID.uuidString, privacy: .public)")
            let result = RunnableDetectResultPayload(
                clientRequestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Project not found on desktop."
            )
            await MobileSyncService.shared.send(.runnableDetectResult(result), toHex: fromHex)
            return
        }

        let detected = await RunProfileDetector().detect(in: project.path)
        logger.info("[MobileSync] runnable detection complete project=\(request.projectID.uuidString, privacy: .public) xcode=\(detected.xcode.count, privacy: .public) npm=\(detected.npm.count, privacy: .public) make=\(detected.make.count, privacy: .public)")
        let result = RunnableDetectResultPayload(
            clientRequestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            detected: detected
        )
        await MobileSyncService.shared.send(.runnableDetectResult(result), toHex: fromHex)
    }

}
