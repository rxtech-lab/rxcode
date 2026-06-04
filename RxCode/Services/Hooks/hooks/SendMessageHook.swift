import Foundation
import os
import RxCodeCore

/// Built-in `.sendMessage` hook. After a clean session stop, if the project has
/// an enabled Send Message hook, it sends a fixed message to the assistant —
/// either as a follow-up turn in the same thread or into a new linked child
/// thread — optionally gated on a model-evaluated condition.
///
/// Once-per-session: the hook marks the session via `HookSetupKind.sendMessage`
/// when it fires and short-circuits while that marker is present. Unlike the
/// commit hook, the marker is *not* self-cleared; it persists until the user
/// sends a genuine new message (reset in `AppState.sendPrompt`). That both
/// prevents the same-thread injected turn from looping and stops the hook
/// re-firing on later automated turns within the same session.
///
/// Runs on `.afterSessionStop`.
@MainActor
final class SendMessageHook: Hook {
    let hookID = "builtin.sendMessage"
    private let logger = Logger(subsystem: "com.claudework", category: "SendMessageHook")
    /// Upper bound on how long to wait for a spawned thread's first response.
    private static let newThreadTimeout: TimeInterval = 120

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        // Once-per-session guard FIRST: if we already fired for this session, do
        // nothing until the user resets it with a new message.
        if controller.isSetupSession(kind: HookSetupKind.sendMessage, sessionKey: payload.sessionKey) {
            return .ignored
        }

        let hooks = await controller.enabledHookProfiles(projectId: payload.project.id, trigger: .afterSessionStop)
            .filter { $0.action == .sendMessage }
        guard let hook = hooks.first, let cfg = hook.sendMessage else { return .ignored }

        let message = cfg.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .ignored }

        // Only act on clean completions; errored/cancelled turns are skipped.
        guard payload.reason == .completed, !payload.turnDidError else { return .ignored }

        // Defer while the user still has queued messages — they run as further
        // turns; act once the queue drains.
        if payload.hasQueuedFollowups { return .ignored }

        // Optional condition gate, evaluated by a (cheap) model.
        if cfg.conditionEnabled,
           let condition = cfg.condition?.trimmingCharacters(in: .whitespacesAndNewlines),
           !condition.isEmpty {
            let verdict = await controller.evaluateCondition(
                condition: condition,
                lastAssistantText: payload.lastAssistantText,
                model: cfg.conditionModel,
                sessionId: payload.sessionId
            )
            guard verdict == true else {
                logger.debug("[Hook] send-message condition not met for session \(payload.sessionId, privacy: .public) verdict=\(String(describing: verdict), privacy: .public)")
                return .ignored
            }
        }

        switch cfg.target {
        case .sameThread:
            let card = controller.insertCard(
                sessionKey: payload.sessionKey,
                toolName: AppState.hookToolName(for: hook),
                input: [
                    "name": .string(hook.name),
                    "trigger": .string(hook.trigger.displayName),
                    "summary": .string("Sending a follow-up message to the assistant…"),
                ]
            )
            controller.completeCard(card, sessionKey: payload.sessionKey, result: "Sent a follow-up message to this thread.", isError: false)
            // Pass `setupKind` so the session is marked AFTER the message is
            // appended (in `sendCrossProject`); marking before would let the
            // injected turn clear its own marker and loop forever.
            logger.debug("[Hook] sending follow-up message into session \(payload.sessionId, privacy: .public)")
            controller.sendThreadMessage(sessionId: payload.sessionId, prompt: message, setupKind: HookSetupKind.sendMessage)
            return .proceed

        case .newThread:
            // The spawned child is a separate session that runs no hooks, so mark
            // the parent now to enforce once-per-session on this thread.
            controller.markSetupSession(kind: HookSetupKind.sendMessage, sessionKey: payload.sessionKey)
            let selection = controller.resolveAgentModelSelection(
                storedModel: cfg.newThreadModel,
                fallbackSessionId: payload.sessionId
            )
            let trimmedLabel = cfg.newThreadLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (trimmedLabel?.isEmpty == false) ? trimmedLabel! : "Assistant"

            let card = controller.insertCard(
                sessionKey: payload.sessionKey,
                toolName: AppState.hookToolName(for: hook),
                input: [
                    "name": .string(hook.name),
                    "trigger": .string(hook.trigger.displayName),
                    "summary": .string("Starting a new thread for the assistant…"),
                ]
            )
            logger.debug("[Hook] spawning linked thread from session \(payload.sessionId, privacy: .public)")
            let result = await controller.spawnLinkedThread(
                projectId: payload.project.id,
                parentThreadId: payload.sessionId,
                label: label,
                agentProvider: selection?.provider,
                model: selection?.model,
                prompt: message,
                timeoutSeconds: Self.newThreadTimeout
            )
            if let result, result.error == nil {
                controller.completeCard(card, sessionKey: payload.sessionKey, result: "Started thread \(result.threadId).", isError: false)
            } else {
                let detail = result?.error ?? "The new thread did not respond in time."
                controller.completeCard(card, sessionKey: payload.sessionKey, result: "Could not start the thread: \(detail)", isError: true)
            }
            return .proceed
        }
    }
}
