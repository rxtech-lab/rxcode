import Foundation
import os
import RxCodeCore

/// Built-in `.commitPush` hook. On a clean session stop, if the project has an
/// enabled Commit & Push hook, it sends a follow-up message into the same thread
/// instructing the agent to commit the changed files and push (the agent decides
/// new vs. existing branch).
///
/// Loop prevention: the follow-up commit turn ends and re-enters this hook. The
/// hook marks the session via `markSetupSession(.commitPush)` before sending, and
/// short-circuits (consuming the marker) whenever it sees that mark — so the
/// commit turn never triggers another commit. It also runs only on clean
/// completions and, when a Code Review hook is also enabled, only after review
/// passed.
///
/// Runs on `.afterSessionStop`.
@MainActor
final class CommitPushHook: Hook {
    let hookID = "builtin.commitPush"
    private let logger = Logger(subsystem: "com.claudework", category: "CommitPushHook")

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        // Loop guard FIRST, so the commit turn always consumes its marker even if
        // that turn errored — otherwise a stale marker would skip the next real
        // turn's commit.
        if controller.isSetupSession(kind: HookSetupKind.commitPush, sessionKey: payload.sessionKey) {
            controller.clearSetupSession(kind: HookSetupKind.commitPush, sessionKey: payload.sessionKey)
            logger.debug("[Hook] commit turn detected for session \(payload.sessionId, privacy: .public) — not re-triggering")
            return .ignored
        }

        let hooks = await controller.enabledHookProfiles(projectId: payload.project.id, trigger: .afterSessionStop)
            .filter { $0.action == .commitPush }
        guard let hook = hooks.first else { return .ignored }

        guard payload.reason == .completed, !payload.turnDidError else { return .ignored }

        // Defer while the user still has queued messages — they'll run as further
        // turns, so don't commit a half-finished change. The next stop (queue
        // drained) triggers the commit.
        if payload.hasQueuedFollowups { return .ignored }

        // Review gate: when a Code Review hook is also configured, only commit if
        // the latest review passed.
        let reviewConfigured = await controller.enabledHookProfiles(projectId: payload.project.id, trigger: .afterSessionStop)
            .contains { $0.action == .codeReview }
        if reviewConfigured {
            let passed = controller.reviewPassed(sessionId: payload.sessionId)
                ?? controller.reviewPassed(sessionId: payload.sessionKey)
            guard passed == true else {
                logger.debug("[Hook] skipping commit for session \(payload.sessionId, privacy: .public) — review not passed (\(String(describing: passed), privacy: .public))")
                return .ignored
            }
        }

        let changedFiles = controller.changedFilePaths(sessionId: payload.sessionId)
        guard !changedFiles.isEmpty else { return .ignored }

        // Mark BEFORE sending so the resulting commit turn short-circuits above.
        controller.markSetupSession(kind: HookSetupKind.commitPush, sessionKey: payload.sessionKey)

        let card = controller.insertCard(
            sessionKey: payload.sessionKey,
            toolName: AppState.hookToolName(for: hook),
            input: [
                "name": .string(hook.name),
                "trigger": .string(hook.trigger.displayName),
                "summary": .string("Asking the agent to commit & push the changes…"),
            ]
        )
        controller.completeCard(card, sessionKey: payload.sessionKey, result: "Requested commit & push of \(changedFiles.count) changed file(s).", isError: false)

        logger.debug("[Hook] requesting commit & push for session \(payload.sessionId, privacy: .public) files=\(changedFiles.count)")
        controller.sendThreadMessage(sessionId: payload.sessionId, prompt: commitPrompt(changedFiles: changedFiles))
        return .proceed
    }

    private func commitPrompt(changedFiles: [String]) -> String {
        let fileList = changedFiles.map { "- \($0)" }.joined(separator: "\n")
        return """
        Commit the changes from this session and push them to the remote.

        Files changed this session:
        \(fileList)

        Steps:
        1. Stage the changed files and create a commit with a clear, conventional commit message describing the change.
        2. Choose an appropriate branch — reuse the current branch if suitable, or create a new branch if that is more appropriate — and push it to the remote (set upstream if needed).
        3. Report the branch name and the pushed commit.

        Do not make further code changes beyond what is needed to commit and push.
        """
    }
}
