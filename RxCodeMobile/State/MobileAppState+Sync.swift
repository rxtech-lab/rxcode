import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI
import UIKit
import os.log
extension MobileAppState {
    // MARK: - Message paging

    /// Ask the desktop for the page of messages immediately older than the
    /// oldest one currently loaded for `sessionID`. No-op when there's nothing
    /// older, a request is already in flight, or the thread has no messages yet.
    /// Returns `true` when a request was dispatched — callers can then expect
    /// `isLoadingMoreMessages(sessionID:)` to flip back to `false` once it
    /// settles.
    @discardableResult
    func loadMoreMessages(sessionID: String) async -> Bool {
        let sessionID = resolveSessionID(sessionID)
        guard isPaired,
              sessionsWithMoreMessages.contains(sessionID),
              !loadingMoreSessions.contains(sessionID),
              let oldest = messagesBySession[sessionID]?.first
        else { return false }

        let requestID = UUID()
        loadingMoreSessions.insert(sessionID)
        pendingLoadMoreRequests[requestID] = sessionID

        let payload = LoadMoreMessagesRequestPayload(
            clientRequestID: requestID,
            sessionID: sessionID,
            beforeMessageID: oldest.id,
            limit: Self.messagePageSize
        )
        do {
            try await client.send(.loadMoreMessages(payload), toHex: pairedDesktopPubkey)
        } catch {
            loadingMoreSessions.remove(sessionID)
            pendingLoadMoreRequests.removeValue(forKey: requestID)
        }
        return true
    }

    /// Fold an older page returned by the desktop into the local window.
    func applyMoreMessages(_ page: MoreMessagesPayload) {
        guard let sessionID = pendingLoadMoreRequests.removeValue(forKey: page.clientRequestID)
        else { return }
        loadingMoreSessions.remove(sessionID)

        if !page.messages.isEmpty {
            var current = messagesBySession[sessionID] ?? []
            let known = Set(current.map(\.id))
            let fresh = page.messages.filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                current.insert(contentsOf: fresh, at: 0)
                messagesBySession[sessionID] = current
            }
        }

        if page.hasMore {
            sessionsWithMoreMessages.insert(sessionID)
        } else {
            sessionsWithMoreMessages.remove(sessionID)
        }
    }

    /// Requests the change overview (thread file edits + uncommitted git
    /// changes) for `sessionID` from the desktop. The reply lands in
    /// `threadChanges` via the `threadChangesResult` payload.
    func requestThreadChanges(sessionID: String) async {
        guard isPaired else { return }
        let sessionID = resolveSessionID(sessionID)
        let requestID = UUID()
        pendingThreadChangesID = requestID
        isLoadingThreadChanges = true
        let payload = ThreadChangesRequestPayload(clientRequestID: requestID, sessionID: sessionID)
        do {
            try await client.send(.threadChangesRequest(payload), toHex: pairedDesktopPubkey)
        } catch {
            if pendingThreadChangesID == requestID {
                pendingThreadChangesID = nil
                isLoadingThreadChanges = false
            }
        }
    }

    func requestRemoteFile(path: String, line: Int?) async {
        guard isPaired else {
            remoteFileResult = RemoteFileResultPayload(
                clientRequestID: UUID(),
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                line: line,
                ok: false,
                errorMessage: String(localized: "Not connected to your Mac.")
            )
            return
        }

        let requestID = UUID()
        pendingRemoteFileID = requestID
        remoteFileResult = nil
        isLoadingRemoteFile = true
        let payload = RemoteFileRequestPayload(clientRequestID: requestID, path: path, line: line)
        do {
            try await client.send(.remoteFileRequest(payload), toHex: pairedDesktopPubkey)
        } catch {
            if pendingRemoteFileID == requestID {
                pendingRemoteFileID = nil
                isLoadingRemoteFile = false
                remoteFileResult = RemoteFileResultPayload(
                    clientRequestID: requestID,
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    line: line,
                    ok: false,
                    errorMessage: String(localized: "Failed to request file: \(error.localizedDescription)")
                )
            }
        }
    }

    func respondToPermission(allow: Bool, denyReason: String? = nil) async {
        guard let pending = pendingPermission else { return }
        let payload = PermissionResponsePayload(
            requestID: pending.requestID,
            allow: allow,
            denyReason: denyReason
        )
        try? await client.send(.permissionResponse(payload), toHex: pairedDesktopPubkey)
        pendingPermission = nil
    }

    // MARK: - AskUserQuestion

    /// Pending `AskUserQuestion` calls for one session, in the order the desktop
    /// queued them.
    func pendingQuestions(sessionID: String) -> [PendingQuestionPayload] {
        let sessionID = resolveSessionID(sessionID)
        return pendingQuestions.filter { $0.sessionID == sessionID }
    }

    /// Submit the user's answers for one `AskUserQuestion` call to the desktop.
    /// The request is dropped from the local queue optimistically; the desktop
    /// re-broadcasts the authoritative queue once it resolves the tool call.
    func answerQuestion(toolUseID: String, answers: [Int: AskUserQuestion.Answer]) async {
        guard isPaired else { return }
        let entries: [QuestionAnswerEntry] = answers.map { index, answer in
            switch answer {
            case .single(let value):
                return QuestionAnswerEntry(questionIndex: index, values: [value], multiSelect: false)
            case .multi(let values):
                return QuestionAnswerEntry(questionIndex: index, values: values, multiSelect: true)
            }
        }
        let payload = QuestionAnswerPayload(toolUseID: toolUseID, answers: entries)
        try? await client.send(.questionAnswer(payload), toHex: pairedDesktopPubkey)
        pendingQuestions.removeAll { $0.toolUseID == toolUseID }
    }

    /// Skip one `AskUserQuestion` call. An empty answer set tells the desktop to
    /// resolve the tool call as denied.
    func skipQuestion(toolUseID: String) async {
        guard isPaired else { return }
        let payload = QuestionAnswerPayload(toolUseID: toolUseID, answers: [])
        try? await client.send(.questionAnswer(payload), toHex: pairedDesktopPubkey)
        pendingQuestions.removeAll { $0.toolUseID == toolUseID }
    }

    func updateDesktopSettings(_ update: MobileSettingsUpdatePayload) async {
        guard isPaired else { return }
        applySettingsUpdateLocally(update)
        try? await client.send(.settingsUpdate(update), toHex: pairedDesktopPubkey)
    }

    func refreshSnapshot() async {
        await requestSnapshot()
    }

    func runProfiles(for projectID: UUID) -> [RunProfile] {
        runProfilesByProject[projectID] ?? []
    }

    func runTasks(for projectID: UUID) -> [MobileRunTaskSnapshot] {
        runTasks.filter { $0.projectId == projectID }
    }

    func runningTask(projectID: UUID, profileID: UUID) -> MobileRunTaskSnapshot? {
        runTasks.first {
            $0.projectId == projectID && $0.profileId == profileID && $0.isRunning
        }
    }

    func saveRunProfile(_ profile: RunProfile, projectID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] save dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public) profile=\(profile.id.uuidString, privacy: .public)")
            return
        }
        var next = runProfilesByProject[projectID] ?? []
        if let idx = next.firstIndex(where: { $0.id == profile.id }) {
            next[idx] = profile
        } else {
            next.append(profile)
        }
        runProfilesByProject[projectID] = next

        let payload = RunProfileMutationRequestPayload(
            projectID: projectID,
            operation: .upsert,
            profile: profile,
            profileID: profile.id
        )
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileMutationRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent save request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profile.id.uuidString, privacy: .public) desktopKey=\(String(self.pairedDesktopPubkey.prefix(12)), privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = String(localized: "Failed to send run profile update: \(error.localizedDescription)")
            logger.error("[RunProfiles] save send failed id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profile.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteRunProfile(projectID: UUID, profileID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] delete dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
            return
        }
        runProfilesByProject[projectID]?.removeAll { $0.id == profileID }
        let payload = RunProfileMutationRequestPayload(
            projectID: projectID,
            operation: .delete,
            profileID: profileID
        )
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileMutationRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent delete request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = String(localized: "Failed to send run profile delete: \(error.localizedDescription)")
            logger.error("[RunProfiles] delete send failed id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func runProfile(projectID: UUID, profileID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] run dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
            return
        }
        let payload = RunProfileRunRequestPayload(projectID: projectID, profileID: profileID)
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileRunRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent run request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = String(localized: "Failed to send run request: \(error.localizedDescription)")
            logger.error("[RunProfiles] run send failed id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public) profile=\(profileID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopRunTask(_ task: MobileRunTaskSnapshot) async {
        guard isPaired else {
            logger.error("[RunProfiles] stop dropped because mobile is not paired task=\(task.taskId.uuidString, privacy: .public)")
            return
        }
        let payload = RunProfileStopRequestPayload(
            taskID: task.taskId,
            projectID: task.projectId,
            profileID: task.profileId
        )
        inFlightRunProfileRequests.insert(payload.clientRequestID)
        do {
            try await client.send(.runProfileStopRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent stop request id=\(payload.clientRequestID.uuidString, privacy: .public) task=\(task.taskId.uuidString, privacy: .public) project=\(task.projectId.uuidString, privacy: .public) profile=\(task.profileId.uuidString, privacy: .public)")
        } catch {
            inFlightRunProfileRequests.remove(payload.clientRequestID)
            lastRunProfileError = String(localized: "Failed to send stop request: \(error.localizedDescription)")
            logger.error("[RunProfiles] stop send failed id=\(payload.clientRequestID.uuidString, privacy: .public) task=\(task.taskId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask the desktop to scan a project for runnable Xcode schemes, npm
    /// scripts, and Make targets. The desktop owns all detection logic; mobile
    /// only renders the result in the run profile editor.
    func requestRunnableDetection(projectID: UUID) async {
        guard isPaired else {
            logger.error("[RunProfiles] detection dropped because mobile is not paired project=\(projectID.uuidString, privacy: .public)")
            return
        }
        let payload = RunnableDetectRequestPayload(projectID: projectID)
        pendingRunnableDetectRequestID = payload.clientRequestID
        runnableDetectInFlight.insert(projectID)
        runnableDetectError = nil
        do {
            try await client.send(.runnableDetectRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[RunProfiles] sent detection request id=\(payload.clientRequestID.uuidString, privacy: .public) project=\(projectID.uuidString, privacy: .public)")
        } catch {
            pendingRunnableDetectRequestID = nil
            runnableDetectInFlight.remove(projectID)
            runnableDetectError = String(localized: "Failed to request detection: \(error.localizedDescription)")
            logger.error("[RunProfiles] detection send failed project=\(projectID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Update the search query and dispatch a debounced search request to the
    /// paired desktop. Empty queries clear results without hitting the network.
    /// Stale requests are discarded by `clientRequestID`.
    func updateSearchQuery(_ query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounceTask?.cancel()
        guard !trimmed.isEmpty else {
            pendingSearchID = nil
            isSearching = false
            searchProjectIDs = []
            searchThreadHits = []
            return
        }
        guard isPaired else {
            isSearching = false
            searchProjectIDs = []
            searchThreadHits = []
            return
        }
        let id = UUID()
        pendingSearchID = id
        isSearching = true
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingSearchID == id else { return }
            let payload = SearchRequestPayload(clientRequestID: id, query: trimmed, limit: 25)
            try? await self.client.send(.searchRequest(payload), toHex: self.pairedDesktopPubkey)
        }
    }

    func reportAPNsToken(hex: String, environment: String) {
        logger.info("[APNs] received token from app delegate tokenPrefix=\(String(hex.prefix(12)), privacy: .public) environment=\(environment, privacy: .public)")
        apnsTokenHex = hex
        apnsEnvironment = environment
        Task { await reportAPNsTokenIfPending() }
    }

    // MARK: - Live Activity & widget

    /// Forward a Live Activity push token (a push-to-start token, a per-activity
    /// update token, or both) to every paired desktop so it can drive the job
    /// Live Activity over APNs. Called by `MobileLiveActivityCoordinator`.
    func sendLiveActivityToken(_ payload: LiveActivityTokenPayload) async {
        guard !pairedDesktops.isEmpty else { return }
        for desktop in pairedDesktops {
            do {
                try await client.send(.liveActivityToken(payload), toHex: desktop.pubkeyHex)
                logger.info("[LiveActivity] token reported startToken=\(payload.pushToStartTokenHex != nil, privacy: .public) activityToken=\(payload.activityTokenHex != nil, privacy: .public) startedLocally=\(payload.activityStartedLocally == true, privacy: .public) dismissed=\(payload.activityDismissed == true, privacy: .public) session=\(payload.sessionID ?? "<nil>", privacy: .public) desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public)")
            } catch {
                logger.error("[LiveActivity] token report failed desktopKey=\(String(desktop.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Recompute the home-screen widget snapshot from the current mirrored
    /// state and persist it into the shared App Group container. Cheap to call
    /// often — `RxCodeWidgetStore` reloads WidgetKit timelines on a real change.
    func refreshWidgetData() {
        let jobCount = sessions.filter { $0.isStreaming }.count
        let snapshot = RxCodeWidgetData(
            jobCount: jobCount,
            ccUsagePercent: desktopUsage?.claudeCode?.fiveHourPercent,
            ccWeeklyUsagePercent: desktopUsage?.claudeCode?.sevenDayPercent,
            codexUsagePercent: desktopUsage?.codex?.fiveHourPercent,
            codexWeeklyUsagePercent: desktopUsage?.codex?.sevenDayPercent,
            updatedAt: Date().timeIntervalSince1970
        )
        RxCodeWidgetStore.save(snapshot)
    }

    /// Routes a tapped APNs notification to its thread. Called by `AppDelegate`'s
    /// `didReceive` handler; `RootView` observes `pendingDeepLink` and navigates.
    func openThreadFromNotification(sessionID: String, projectID: UUID?) {
        logger.info("[APNs] notification tap -> open thread sessionID=\(sessionID, privacy: .public) projectID=\(projectID?.uuidString ?? "<nil>", privacy: .public)")
        pendingDeepLink = MobileDeepLink(sessionID: sessionID, projectID: projectID)
    }

    func switchPairedDesktop(_ desktop: PairedDesktop) async {
        guard pairedDesktops.contains(where: { $0.id == desktop.id }) else { return }
        // Allow switching even to the same pubkey if it's a different relay pairing
        guard desktop.id != activePairedDesktop?.id else { return }
        clearDesktopMirror()
        // Switch to the relay this pairing uses, then set the active desktop
        if let relayString = desktop.relayURL, let relayURL = URL(string: relayString) {
            await updateRelayForPairingIfNeeded(relayURL)
        }
        setActiveDesktop(pubkeyHex: desktop.pubkeyHex)
        savePairedDesktops()
        try? await client.addPeer(desktop.pubkeyHex)
        await requestSnapshot()
        await reportAPNsTokenIfPending()
    }

    func removePairedDesktop(_ desktop: PairedDesktop) async {
        let wasActive = desktop.id == activePairedDesktop?.id
        let pubkeyHex = desktop.pubkeyHex

        // Optimistically remove from UI first for immediate feedback
        pairedDesktops.removeAll { $0.id == desktop.id }

        if wasActive {
            clearDesktopMirror()
            setActiveDesktop(pubkeyHex: pairedDesktops.first?.pubkeyHex)
        } else {
            setActiveDesktop(pubkeyHex: pairedDesktopPubkey)
        }
        savePairedDesktops()

        // Notify desktop and clean up peer connection (best-effort, ignore failures)
        try? await client.send(.unpair(UnpairPayload(reason: "mobile")), toHex: pubkeyHex)
        // Only remove the crypto peer if no other pairings use the same pubkey
        if !pairedDesktops.contains(where: { $0.pubkeyHex == pubkeyHex }) {
            await client.removePeer(pubkeyHex)
        }

        if wasActive, isPaired {
            await requestSnapshot()
            await reportAPNsTokenIfPending()
        }
    }

    func unpair() async {
        guard let desktop = activePairedDesktop else { return }
        await removePairedDesktop(desktop)
    }

    func clearDesktopMirror() {
        hasReceivedInitialSnapshot = false
        projects = []
        sessions = []
        branchBriefings = []
        threadSummaries = []
        ciStatusByProject = [:]
        desktopSettings = nil
        desktopUsage = nil
        desktopHostMetrics = nil
        desktopWebProxy = nil
        projectBranches = [:]
        availableBranchesByProject = [:]
        runProfilesByProject = [:]
        runTasks = []
        inFlightRunProfileRequests = []
        lastRunProfileError = nil
        inFlightBranchOps = []
        lastBranchOpError = nil
        messagesBySession = [:]
        thinkingSessions = []
        sessionsWithMoreMessages = []
        loadingMoreSessions = []
        pendingLoadMoreRequests = [:]
        remoteFolderRoot = nil
        remoteFolderIsLoading = false
        remoteFolderError = nil
        remoteProjectCreateInFlight = false
        remoteProjectCreateError = nil
        pendingFolderTreeRequestID = nil
        pendingCreateProjectRequestID = nil
        lastCreatedProjectID = nil
        activeSessionID = nil
        pendingPermission = nil
        pendingQuestions = []
        skillCatalog = []
        skillCatalogLoading = false
        skillCatalogError = nil
        skillSources = []
        inFlightSkillMutations = []
        inFlightSkillSourceMutations = []
        lastSkillError = nil
        pendingSkillCatalogRequestID = nil
        skillSourceMutationKeys = [:]
        acpRegistryAgents = []
        acpInstalledClients = []
        acpRegistryLoading = false
        acpRegistryError = nil
        inFlightACPMutations = []
        lastACPError = nil
        pendingACPRegistryRequestID = nil
        acpMutationKeys = [:]
        mcpServers = []
        mcpConfigLoading = false
        mcpConfigError = nil
        inFlightMCPMutations = []
        lastMCPError = nil
        pendingMCPConfigRequestID = nil
        autopilotAccount = nil
        let pendingAutopilot = pendingAutopilotRequests
        pendingAutopilotRequests = [:]
        for continuation in pendingAutopilot.values {
            continuation.resume(throwing: AutopilotRemoteError.desktopChanged)
        }
    }
}
