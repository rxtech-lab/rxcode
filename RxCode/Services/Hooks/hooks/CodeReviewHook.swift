import Foundation
import os
import RxCodeCore

/// Built-in `.codeReview` hook. On a clean session stop, if the project has an
/// enabled Code Review hook, it spawns a linked `[Code Review]` thread (running
/// no hooks, using the configured or inherited model) and feeds it the changed
/// files, the user's task, and the agent's final response. The reviewer ends its
/// reply with `REVIEW_RESULT: PASS` or `REVIEW_RESULT: FAIL`:
///   - PASS → records the verdict so `CommitPushHook` may proceed.
///   - FAIL → sends the review notes back into the original thread as a
///     follow-up prompt so the agent fixes the issues and is then re-reviewed.
///     Bounded by `maxReviewRounds` to stop a fix→fail→fix loop.
///   - No verdict marker (a cancelled/interrupted review, or a reply missing the
///     marker) → records not-passed but does NOT re-prompt, so a manually
///     cancelled review never kicks off an auto-retry turn.
///
/// Runs on `.afterSessionStop` (after the thread is finalized/saved). Registered
/// last so its (possibly long) work doesn't delay the response notification.
@MainActor
final class CodeReviewHook: Hook {
    let hookID = "builtin.codeReview"
    private let logger = Logger(subsystem: "com.claudework", category: "CodeReviewHook")

    /// Verdict marker the reviewer must end its reply with.
    private static let marker = "REVIEW_RESULT:"
    /// Upper bound on how long to wait for the review thread's first response.
    private static let reviewTimeout: TimeInterval = 600
    /// Max failed-review re-prompts per session before giving up.
    private static let maxReviewRounds = 3

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        // Only review clean completions; errored/cancelled turns aren't reviewable.
        guard payload.reason == .completed, !payload.turnDidError else { return .ignored }

        // Don't review the follow-up commit turn the Commit & Push hook triggered
        // (file edits are thread-cumulative, so the original change would look
        // "changed" again and spawn a redundant review). The marker is still set
        // here because CommitPushHook clears it later in this same dispatch (it is
        // registered after this hook).
        if controller.isSetupSession(kind: HookSetupKind.commitPush, sessionKey: payload.sessionKey) {
            return .ignored
        }

        let hooks = await controller.enabledHookProfiles(projectId: payload.project.id, trigger: .afterSessionStop)
            .filter { $0.action == .codeReview }
        guard let hook = hooks.first else { return .ignored }

        // Defer while the user still has queued messages — they'll run as further
        // turns, so don't review a half-finished change. The next stop (queue
        // drained) triggers the review.
        if payload.hasQueuedFollowups { return .ignored }

        let changedFiles = controller.changedFilePaths(sessionId: payload.sessionId)
        guard !changedFiles.isEmpty else {
            // Nothing changed — treat as passed so a paired commit hook can no-op
            // cleanly rather than waiting on a review that has nothing to review.
            recordVerdict(true, payload: payload, controller: controller)
            return .ignored
        }

        let task = controller.firstUserPrompt(sessionId: payload.sessionKey) ?? "(task unknown)"
        let selection = controller.resolveAgentModelSelection(
            storedModel: hook.codeReview?.model,
            fallbackSessionId: payload.sessionId
        )
        let prompt = reviewPrompt(
            task: task,
            changedFiles: changedFiles,
            finalResponse: payload.lastAssistantText,
            extraInstructions: hook.codeReview?.instructions
        )

        let card = controller.insertCard(
            sessionKey: payload.sessionKey,
            toolName: AppState.hookToolName(for: hook),
            input: [
                "name": .string(hook.name),
                "trigger": .string(hook.trigger.displayName),
                "summary": .string("Code review · \(changedFiles.count) changed file(s)"),
            ]
        )
        // Persist the card in-progress so it survives a reload while the review
        // (which can take minutes) is still running. `finishCard` updates it.
        controller.persistHookStatus(
            sessionKey: payload.sessionKey,
            toolId: card.toolId,
            name: hook.name,
            trigger: hook.trigger.displayName,
            output: "",
            isError: false,
            isComplete: false
        )

        logger.debug("[Hook] spawning code-review thread for session \(payload.sessionId, privacy: .public) files=\(changedFiles.count)")
        let result = await controller.spawnLinkedThread(
            projectId: payload.project.id,
            parentThreadId: payload.sessionId,
            label: "Code Review",
            agentProvider: selection?.provider,
            model: selection?.model,
            prompt: prompt,
            timeoutSeconds: Self.reviewTimeout
        )

        guard let result, result.error == nil else {
            // Couldn't run the review (transport/agent error or timeout). Don't
            // punish the agent for our own failure — record as not-passed (so a
            // commit hook holds off) but don't re-prompt.
            let detail = result?.error ?? "The review thread did not respond in time."
            finishCard(card, hook: hook, payload: payload, controller: controller,
                       result: "Code review could not complete: \(detail)", isError: true)
            recordVerdict(false, payload: payload, controller: controller)
            return .ignored
        }

        let verdict = parseVerdict(result.assistantText)
        // Fold the review thread's full activity into the card so it can be
        // expanded inline on the parent thread (and on paired mobile devices,
        // since hook cards sync automatically).
        let transcript = controller.threadTranscript(sessionId: result.threadId)
        let body = transcript.isEmpty ? result.assistantText : transcript
        let reviewLink = "Review thread: \(result.threadId)"

        switch verdict {
        case .pass:
            finishCard(card, hook: hook, payload: payload, controller: controller,
                       result: "✅ Code review passed.\n\(reviewLink)\n\n\(body)", isError: false)
            recordVerdict(true, payload: payload, controller: controller)
            controller.setReviewRound(0, sessionId: payload.sessionId)
            return .proceed

        case .fail(let notes):
            recordVerdict(false, payload: payload, controller: controller)
            let round = controller.reviewRound(sessionId: payload.sessionId)
            if round + 1 >= Self.maxReviewRounds {
                // Give up re-prompting after the cap so a perpetually-failing
                // review can't loop the agent forever.
                controller.setReviewRound(0, sessionId: payload.sessionId)
                finishCard(card, hook: hook, payload: payload, controller: controller,
                           result: "⚠️ Code review still requesting changes after \(Self.maxReviewRounds) attempts — stopping.\n\(reviewLink)\n\n\(body)",
                           isError: true)
                return .proceed
            }

            controller.setReviewRound(round + 1, sessionId: payload.sessionId)
            finishCard(card, hook: hook, payload: payload, controller: controller,
                       result: "⚠️ Code review requested changes (sent back to the agent, attempt \(round + 1) of \(Self.maxReviewRounds)).\n\(reviewLink)\n\n\(body)",
                       isError: true)
            // After-stop can't auto-continue, so re-prompt the thread directly.
            controller.sendThreadMessage(
                sessionId: payload.sessionId,
                prompt: """
                A Code Review of your change requested changes. Address the feedback below, then finish.

                \(notes)
                """
            )
            return .proceed

        case .unknown:
            // The reviewer ended without a PASS/FAIL marker. The dominant cause
            // is a review thread the user manually cancelled (or one that was
            // interrupted) — its partial reply has no verdict. Don't auto-retry:
            // record not-passed (so a paired commit hook still holds off) and
            // finish the card, but leave the agent alone. A genuine "reviewer
            // forgot the marker" is rare and is better surfaced quietly here than
            // by silently kicking off an unwanted fix turn.
            recordVerdict(false, payload: payload, controller: controller)
            controller.setReviewRound(0, sessionId: payload.sessionId)
            finishCard(card, hook: hook, payload: payload, controller: controller,
                       result: "⚠️ Code review ended without a verdict (it may have been cancelled or interrupted) — not retrying.\n\(reviewLink)\n\n\(body)",
                       isError: true)
            return .ignored
        }
    }

    /// Complete the card and persist it as the session's "last hook" so the
    /// folded review survives an app reload (hook cards never reach the transcript).
    private func finishCard(
        _ card: HookCardHandle,
        hook: HookProfile,
        payload: SessionEndPayload,
        controller: any HookController,
        result: String,
        isError: Bool
    ) {
        controller.completeCard(card, sessionKey: payload.sessionKey, result: result, isError: isError)
        controller.persistHookStatus(
            sessionKey: payload.sessionKey,
            toolId: card.toolId,
            name: hook.name,
            trigger: hook.trigger.displayName,
            output: result,
            isError: isError,
            isComplete: true
        )
    }

    // MARK: - Helpers

    private func recordVerdict(_ passed: Bool, payload: SessionEndPayload, controller: any HookController) {
        // Store under both the in-memory key and the resolved id; the commit hook
        // reads whichever it sees first.
        controller.setReviewPassed(passed, sessionId: payload.sessionId)
        controller.setReviewPassed(passed, sessionId: payload.sessionKey)
    }

    private enum Verdict {
        case pass
        case fail(notes: String)
        case unknown(notes: String)
    }

    private func parseVerdict(_ text: String) -> Verdict {
        // Scan from the end so a trailing verdict line wins over any earlier
        // mention of the marker in the body.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines.reversed() {
            guard let range = line.range(of: Self.marker, options: [.caseInsensitive]) else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if value.hasPrefix("PASS") { return .pass }
            if value.hasPrefix("FAIL") { return .fail(notes: text) }
        }
        // No verdict marker — be conservative and treat as needing attention.
        return .unknown(notes: text)
    }

    private func reviewPrompt(task: String, changedFiles: [String], finalResponse: String, extraInstructions: String?) -> String {
        let fileList = changedFiles.map { "- \($0)" }.joined(separator: "\n")
        var prompt = """
        You are reviewing another agent's code change in this repository. Do not edit any files — only review.

        ## The user's task
        \(task)

        ## Files the agent changed
        \(fileList)

        ## The agent's final response
        \(finalResponse)

        ## What to do
        Inspect the changed files and judge whether the change correctly and safely accomplishes the task. Look for bugs, missed requirements, regressions, and obvious quality problems.

        End your reply with a single line — exactly one of:
        `\(Self.marker) PASS`  (the change is good as-is)
        `\(Self.marker) FAIL`  (changes are needed)

        If you FAIL the review, list the specific, actionable issues to fix above that line.
        """
        if let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            prompt += "\n\n## Additional instructions\n\(extra)"
        }
        return prompt
    }
}
