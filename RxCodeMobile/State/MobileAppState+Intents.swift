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
    func sendUserMessage(_ text: String, sessionID: String) async {
        guard isPaired else { return }
        let payload = UserMessagePayload(sessionID: sessionID, text: text)
        try? await client.send(.userMessage(payload), toHex: pairedDesktopPubkey)
    }

    func cancelStream(sessionID: String) async {
        guard isPaired else { return }
        let payload = CancelStreamPayload(sessionID: sessionID)
        try? await client.send(.cancelStream(payload), toHex: pairedDesktopPubkey)
    }

    func removeQueuedMessage(sessionID: String, queuedID: UUID) async {
        guard isPaired else { return }
        let payload = RemoveQueuedMessagePayload(sessionID: sessionID, queuedMessageID: queuedID)
        try? await client.send(.removeQueuedMessage(payload), toHex: pairedDesktopPubkey)
    }

    /// True iff the desktop reports the given session as actively streaming.
    func isSessionStreaming(_ sessionID: String) -> Bool {
        sessions.first(where: { $0.id == sessionID })?.isStreaming ?? false
    }

    /// True iff the desktop reports the given session as currently producing
    /// reasoning/thinking tokens.
    func isSessionThinking(_ sessionID: String) -> Bool {
        thinkingSessions.contains(sessionID)
    }

    /// Whether the given session has messages older than the loaded window.
    func hasMoreMessages(sessionID: String) -> Bool {
        sessionsWithMoreMessages.contains(sessionID)
    }

    /// Whether an older page is currently being fetched for the given session.
    func isLoadingMoreMessages(sessionID: String) -> Bool {
        loadingMoreSessions.contains(sessionID)
    }

    /// Mirror of the desktop's per-session queue, surfaced via `SessionSummary`.
    func queuedMessages(sessionID: String) -> [QueuedUserMessage] {
        sessions.first(where: { $0.id == sessionID })?.queuedMessages ?? []
    }

    /// Ask the desktop to create a new thread. The per-thread agent config
    /// (model, permission mode, plan mode) travels in the request so the thread
    /// is created with exactly the chosen config — fixing the bug where a
    /// non-default model was dropped in favor of the project default. ACP client
    /// and effort have no mobile picker, so they ride along from the last synced
    /// desktop settings.
    func requestNewSession(
        projectID: UUID,
        initialText: String? = nil,
        agentProvider: AgentProvider? = nil,
        model: String? = nil,
        permissionMode: PermissionMode? = nil,
        planMode: Bool = false
    ) async {
        guard isPaired else { return }
        let payload = NewSessionRequestPayload(
            projectID: projectID,
            initialText: initialText,
            selectedAgentProvider: agentProvider,
            selectedModel: model,
            selectedACPClientId: desktopSettings?.selectedACPClientId,
            selectedEffort: desktopSettings?.selectedEffort,
            permissionMode: permissionMode,
            planMode: planMode
        )
        try? await client.send(.newSessionRequest(payload), toHex: pairedDesktopPubkey)
    }

    func requestRemoteFolder(path: String? = nil) async {
        guard isPaired else { return }
        let request = FolderTreeRequestPayload(path: path, depth: 1)
        pendingFolderTreeRequestID = request.clientRequestID
        remoteFolderIsLoading = true
        remoteFolderError = nil
        do {
            try await client.send(.folderTreeRequest(request), toHex: pairedDesktopPubkey)
        } catch {
            pendingFolderTreeRequestID = nil
            remoteFolderIsLoading = false
            remoteFolderError = error.localizedDescription
        }
    }

    func createProjectFromRemoteFolder(path: String) async {
        guard isPaired else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let request = CreateProjectRequestPayload(path: trimmed)
        pendingCreateProjectRequestID = request.clientRequestID
        remoteProjectCreateInFlight = true
        remoteProjectCreateError = nil
        do {
            try await client.send(.createProjectRequest(request), toHex: pairedDesktopPubkey)
        } catch {
            pendingCreateProjectRequestID = nil
            remoteProjectCreateInFlight = false
            remoteProjectCreateError = error.localizedDescription
        }
    }

    // MARK: - Plan mode

    /// Plan cards for a session, derived live from the synced messages using the
    /// shared `PlanLogic` — the same `ExitPlanMode` detection the desktop chat
    /// uses. Superseded plans (re-emitted within the same turn) are dropped so
    /// only actionable cards surface.
    func pendingPlans(sessionID: String) -> [PendingPlan] {
        let messages = messagesBySession[sessionID] ?? []
        var plans: [PendingPlan] = []
        for message in messages {
            for block in message.blocks {
                guard let toolCall = block.toolCall,
                      PlanLogic.isExitPlanMode(toolCall) else { continue }
                if PlanLogic.isSupersededExitPlanMode(
                    toolCall: toolCall, in: message, allMessages: messages
                ) { continue }
                let markdown = PlanLogic.renderMarkdown(for: toolCall, in: message) ?? ""
                let decided = PlanLogic.isPlanDecided(toolCall)
                plans.append(PendingPlan(
                    toolCallId: toolCall.id,
                    markdown: markdown,
                    isStreaming: !decided && markdown.isEmpty && message.isStreaming,
                    isDecided: decided,
                    decisionSummary: decided ? toolCall.result : nil
                ))
            }
        }
        return plans
    }

    /// Send the user's plan decision to the desktop, which resolves the CLI
    /// `ExitPlanMode` hook via `respondToPlanDecision`. No optimistic mutation —
    /// the desktop broadcasts the updated `toolCall.result` back through the
    /// normal session-update sync, so the banner and chat reconcile from that.
    func respondToPlanDecision(
        toolUseID: String,
        sessionID: String,
        action: PlanDecisionAction
    ) async {
        guard isPaired else { return }
        let payload = PlanDecisionPayload(
            toolUseID: toolUseID,
            sessionID: sessionID,
            decision: action
        )
        try? await client.send(.planDecision(payload), toHex: pairedDesktopPubkey)
    }

    // MARK: - Thread lifecycle actions

    /// Rename a thread. The local title is updated optimistically; the desktop
    /// confirms via the next snapshot / session update.
    func renameThread(sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replaceSession(sessionID: sessionID) { current in
            SessionSummary(
                id: current.id,
                projectId: current.projectId,
                title: trimmed,
                updatedAt: current.updatedAt,
                isPinned: current.isPinned,
                isArchived: current.isArchived,
                isStreaming: current.isStreaming,
                attention: current.attention,
                progress: current.progress,
                queuedMessages: current.queuedMessages
            )
        }
        await sendThreadAction(sessionID: sessionID, action: .rename, newTitle: trimmed)
    }

    /// Archive a thread. Optimistically flips `isArchived` so the row drops out
    /// of the active list right away.
    func archiveThread(sessionID: String) async {
        replaceSession(sessionID: sessionID) { current in
            SessionSummary(
                id: current.id,
                projectId: current.projectId,
                title: current.title,
                updatedAt: current.updatedAt,
                isPinned: current.isPinned,
                isArchived: true,
                isStreaming: current.isStreaming,
                attention: current.attention,
                progress: current.progress,
                queuedMessages: current.queuedMessages
            )
        }
        await sendThreadAction(sessionID: sessionID, action: .archive)
    }

    /// Delete a thread. Optimistically drops it from local state.
    func deleteThread(sessionID: String) async {
        sessions.removeAll { $0.id == sessionID }
        messagesBySession.removeValue(forKey: sessionID)
        sessionsWithMoreMessages.remove(sessionID)
        loadingMoreSessions.remove(sessionID)
        if activeSessionID == sessionID { activeSessionID = nil }
        await sendThreadAction(sessionID: sessionID, action: .delete)
    }

    func replaceSession(sessionID: String, _ transform: (SessionSummary) -> SessionSummary) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index] = transform(sessions[index])
    }

    func sendThreadAction(
        sessionID: String,
        action: ThreadActionRequestPayload.Action,
        newTitle: String? = nil
    ) async {
        guard isPaired else {
            logger.error("[ThreadAction] not paired — dropping action=\(action.rawValue, privacy: .public)")
            return
        }
        let payload = ThreadActionRequestPayload(
            sessionID: sessionID,
            action: action,
            newTitle: newTitle
        )
        do {
            try await client.send(.threadActionRequest(payload), toHex: pairedDesktopPubkey)
            logger.info("[ThreadAction] sent action=\(action.rawValue, privacy: .public) thread=\(sessionID, privacy: .public)")
        } catch {
            logger.error("[ThreadAction] send failed action=\(action.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tell the desktop to switch the project to an existing local branch.
    /// Returns immediately; the eventual snapshot broadcast carries the new
    /// `currentBranch` and any error surfaces via `lastBranchOpError`.
    func switchProjectBranch(projectID: UUID, branch: String) async {
        guard isPaired else { return }
        let request = BranchOpRequestPayload(
            projectID: projectID,
            operation: .switchExisting,
            branch: branch
        )
        inFlightBranchOps.insert(request.clientRequestID)
        try? await client.send(.branchOpRequest(request), toHex: pairedDesktopPubkey)
    }

    /// Tell the desktop to create a new branch + worktree off the current
    /// branch. The desktop parks the worktree against the project so the next
    /// new-thread request for this project spawns into it.
    func createProjectBranch(projectID: UUID, branch: String) async {
        guard isPaired else { return }
        let request = BranchOpRequestPayload(
            projectID: projectID,
            operation: .createNew,
            branch: branch
        )
        inFlightBranchOps.insert(request.clientRequestID)
        try? await client.send(.branchOpRequest(request), toHex: pairedDesktopPubkey)
    }

    func clearBranchOpError() {
        lastBranchOpError = nil
    }

    func subscribe(to sessionID: String?) async {
        activeSessionID = sessionID
        guard isPaired else { return }
        let payload = SubscribeSessionPayload(sessionID: sessionID)
        try? await client.send(.subscribeSession(payload), toHex: pairedDesktopPubkey)
    }
}
