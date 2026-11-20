import AppKit
import Foundation
import os
import RxCodeCore
import SwiftUI

extension AppStateHookController {
    // MARK: Review debounce / cancellation

    var reviewCountdownSeconds: TimeInterval { ReviewScheduler.defaultDelaySeconds }

    func awaitReviewGate(parentSessionKey: String, delaySeconds: TimeInterval) async -> Bool {
        guard let app else { return true }
        let outcome = await app.reviewScheduler.awaitGate(parentSessionKey: parentSessionKey, delaySeconds: delaySeconds)
        return outcome == .proceed
    }

    func markReviewRunning(parentSessionKey: String) {
        app?.reviewScheduler.markRunning(parentSessionKey: parentSessionKey)
    }

    func clearReviewRunning(parentSessionKey: String) {
        app?.reviewScheduler.clearRunning(parentSessionKey: parentSessionKey)
    }

    func reviewWasStopped(parentSessionKey: String) -> Bool {
        app?.reviewScheduler.consumeStoppedWhileRunning(parentSessionKey: parentSessionKey) ?? false
    }

    func reviewCancelReason(parentSessionKey: String) -> ReviewCancelReason? {
        app?.reviewScheduler.cancelReason(parentSessionKey: parentSessionKey)
    }

    func threadHasOngoingReview(sessionId: String) -> Bool {
        app?.reviewScheduler.hasOngoingReview(parentSessionKey: sessionId) ?? false
    }

    func threadHasNewerActivity(sessionId: String) -> Bool {
        guard let app else { return false }
        let state = app.stateForSession(sessionId)
        // A new turn streaming on this thread.
        if state.isStreaming { return true }
        // Walk back to the latest *meaningful* message, skipping synthetic cards
        // inserted by hooks (hook status cards, auto-continue, the review
        // countdown). A trailing user message means a follow-up superseded the
        // completed turn; an assistant turn — whether it ended with prose or only
        // real tool calls (e.g. file edits and no closing text) — is just the
        // turn's own response, not newer activity.
        for message in state.messages.reversed() {
            switch message.role {
            case .user:
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            case .assistant:
                // First real assistant message reached → the completed turn's
                // response. Synthetic-only / empty rows fall through and we keep
                // looking past them.
                if Self.isMeaningfulAssistantMessage(message) { return false }
            }
        }
        return false
    }

    /// Whether an assistant message carries real activity — non-empty prose or at
    /// least one non-synthetic tool call. Hook status cards, the auto-continue
    /// card, and the review-countdown card are synthetic and don't count.
    private static func isMeaningfulAssistantMessage(_ message: ChatMessage) -> Bool {
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return message.blocks.compactMap { $0.toolCall }.contains { !isSyntheticToolName($0.name) }
    }

    private static func isSyntheticToolName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("hook:")
            || name == ToolCall.autoContinueToolName
            || name == ReviewCountdownCard.toolName
    }

    func setReviewPassed(_ passed: Bool, sessionId: String) {
        app?.reviewPassedBySession[sessionId] = passed
        // Persist on the thread row so the sidebar review dot survives a reload.
        app?.threadStore.setReviewPassed(sessionId: sessionId, passed: passed)
    }

    func reviewPassed(sessionId: String) -> Bool? {
        app?.reviewPassedBySession[sessionId]
    }

    func reviewRound(sessionId: String) -> Int {
        app?.reviewRoundBySession[sessionId] ?? 0
    }

    func setReviewRound(_ round: Int, sessionId: String) {
        guard let app else { return }
        if round == 0 {
            app.reviewRoundBySession[sessionId] = nil
        } else {
            app.reviewRoundBySession[sessionId] = round
        }
    }

    func lastReviewFeedback(sessionId: String) -> String? {
        app?.lastReviewFeedbackBySession[sessionId]
    }

    func setLastReviewFeedback(_ feedback: String?, sessionId: String) {
        let trimmed = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
        app?.lastReviewFeedbackBySession[sessionId] = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
