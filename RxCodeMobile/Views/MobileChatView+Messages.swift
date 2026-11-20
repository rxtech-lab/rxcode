import Foundation
import OSLog
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension MobileChatView {
    // MARK: - Initial loading

    func runThreadLoadingGate() async {
        minimumThreadLoadElapsed = false
        threadLoadingHideTask?.cancel()
        isThreadLoadingOverlayVisible = true
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            minimumThreadLoadElapsed = true
        }
        scheduleThreadLoadingHideIfReady()
    }

    func handleThreadLoadingChange(_ isLoading: Bool) {
        threadLoadingHideTask?.cancel()
        guard !MobileDraftSessionID.isDraft(sessionID) else {
            isThreadLoadingOverlayVisible = false
            return
        }
        guard !isLoading else {
            isThreadLoadingOverlayVisible = true
            return
        }
        scheduleThreadLoadingHideIfReady()
    }

    private func scheduleThreadLoadingHideIfReady() {
        threadLoadingHideTask?.cancel()
        guard !MobileDraftSessionID.isDraft(sessionID) else {
            isThreadLoadingOverlayVisible = false
            return
        }
        guard minimumThreadLoadElapsed, !isThreadLoadingMessages else {
            isThreadLoadingOverlayVisible = true
            return
        }
        isThreadLoadingOverlayVisible = true
        threadLoadingHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isThreadLoadingOverlayVisible = false
            }
        }
    }

    // MARK: - Message paging

    func loadMorePreviousMessages() async throws {
        _ = await state.loadMoreMessages(sessionID: sessionID)
    }

    func establishInitialPackageScroll(reason: String) {
        guard !didEstablishInitialScroll else {
            isInitialMessageListHidden = false
            return
        }
        guard !messages.isEmpty else { return }
        didEstablishInitialScroll = true
        isInitialMessageListHidden = true
        requestPackageScrollToBottom(reason: reason)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeInOut(duration: 0.18)) {
                isInitialMessageListHidden = false
            }
        }
    }

    func requestPackageScrollToBottom(reason: String) {
        // Coalesce geometry changes during keyboard animation instead of
        // cancelling and restarting a scroll task on every frame.
        if reason == "button" {
            packageScrollRequestTask?.cancel()
            packageScrollRequestTask = nil
        }
        guard packageScrollRequestTask == nil else { return }
        packageScrollAnimated = reason == "button"
        packageShouldScrollToBottom = false
        Self.logger.debug(
            "PERFORMANCE: [MessageList] scrollToBottom requested reason=\(reason, privacy: .public) session=\(sessionID, privacy: .public)"
        )
        packageScrollRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            packageScrollRequestTask = nil
            packageShouldScrollToBottom = true
        }
    }

    // MARK: - Send / Stop

    func handleSend(_ trimmed: String) {
        // The sent message round-trips through the desktop; when it comes back
        // it is pinned to the top. Suppress bottom-follow so the streaming
        // reply fills the space below the question instead of yanking past it.
        autoBottomScrollTask?.cancel()
        autoBottomScrollTask = nil
        awaitingSentUserMessage = true
        activeTurnUserMessageID = nil
        pendingIndicatorSpacerReduction = 0
        isPinningLatestTurnToTop = false
        canReleasePinnedTurnByScroll = false
        autoScrollEnabled = false
        Task {
            await state.sendUserMessage(trimmed, sessionID: sessionID)
        }
    }

    // MARK: - Pin to top

    /// The user message whose geometry drives the active turn spacer. During a
    /// send this stays attached to that turn even if the user manually scrolls.
    private var trackedUserMessageID: UUID? {
        activeTurnUserMessageID ?? messages.last(where: { $0.role == .user })?.id
    }

    /// Visible chat area above the floating composer. `composerMinY` rides up
    /// with the keyboard, so this shrinks automatically when the keyboard opens.
    private var availableHeight: CGFloat {
        guard composerMinY > 0, scrollViewMinY > 0 else { return scrollViewHeight }
        return max(0, composerMinY - scrollViewMinY)
    }

    /// Minimum tail spacer: keeps the last line of a long reply clear of the
    /// area covered by the composer (and keyboard).
    var minTailSpacer: CGFloat {
        max(0, scrollViewHeight - availableHeight) + 16
    }

    /// Keeps the floating scroll button above the composer, including queued
    /// message/question/plan banners and the keyboard-driven composer lift.
    var scrollToBottomButtonBottomPadding: CGFloat {
        guard composerMinY > 0, scrollViewMinY > 0 else { return 80 }
        let coveredHeight = max(0, scrollViewMinY + scrollViewHeight - composerMinY)
        return coveredHeight + 12
    }

    /// Extra spacer for the active turn. It starts large enough for the sent
    /// user message to sit at the top, then shrinks as the assistant response
    /// grows into that space. Manual scroll releases active top-following, but
    /// the spacer remains attached to the turn so the layout can recover.
    private var pinTailSpacerExtraHeight: CGFloat {
        guard activeTurnUserMessageID != nil else { return 0 }
        guard scrollViewHeight > 0 else { return 0 }
        let latestTurnHeight = max(0, tailSpacerMinY - latestUserMinY)
            + pendingIndicatorSpacerReduction
        return max(0, scrollViewHeight - latestTurnHeight - minTailSpacer)
    }

    func handleStop() {
        guard !sessionID.isEmpty else { return }
        Task { await state.cancelStream(sessionID: sessionID) }
    }

    func removeQueued(_ queued: QueuedUserMessage) {
        Task { await state.removeQueuedMessage(sessionID: sessionID, queuedID: queued.id) }
    }
}
