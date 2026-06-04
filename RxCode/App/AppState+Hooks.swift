import Foundation
import os
import RxCodeChatKit
import RxCodeCore

extension AppState {
    // MARK: - Per-project hook cache (mirrors run profiles)

    func hookProfiles(for projectId: UUID) -> [HookProfile] {
        hookProfilesByProject[projectId] ?? []
    }

    /// Load this project's hooks from disk if we haven't already. No-op if loaded.
    func ensureHookProfilesLoaded(for projectId: UUID) async {
        if hookProfilesByProject[projectId] != nil { return }
        let loaded = await persistence.loadHookProfiles(projectId: projectId)
        hookProfilesByProject[projectId] = loaded
    }

    /// Replace the in-memory list and persist atomically.
    func setHookProfiles(_ profiles: [HookProfile], for projectId: UUID) {
        hookProfilesByProject[projectId] = profiles
        Task { [persistence] in
            do {
                try await persistence.saveHookProfiles(profiles, projectId: projectId)
            } catch {
                logger.error("Failed to save hook profiles: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - New-chat banner hooks

    /// Run the "new chat started" hooks for a project's empty-state / composer
    /// screen — e.g. the Autopilot `.env` backup banner. This used to fire only
    /// inside the stream preflight (on first message send), so the banner never
    /// appeared just from opening the screen. Views call this from `.task(id:)`
    /// when a project's chat screen appears. The hook itself decides whether to
    /// show or dismiss its banner, so this is safe to call repeatedly.
    func runProjectNewChatHooks(projectId: UUID, sessionKey: String) async {
        logger.debug("[Hook] runProjectNewChatHooks: projectId=\(projectId.uuidString, privacy: .public) sessionKey=\(sessionKey, privacy: .public)")
        await hookManager.dispatchProjectNewChatStart(
            NewChatStartPayload(projectId: projectId, sessionKey: sessionKey)
        )
    }

    func projectContextMenuItems(for project: Project) -> [HookMenuItem] {
        hookManager.projectContextMenuItems(ProjectContextMenuPayload(project: project))
    }

    func threadContextMenuItems(for session: ChatSession.Summary) -> [HookMenuItem] {
        guard let project = projects.first(where: { $0.id == session.projectId }) else { return [] }
        return hookManager.threadContextMenuItems(ThreadContextMenuPayload(project: project, session: session))
    }

    // MARK: - Hook execution

    /// Tool-call name carried by a hook's chat card. The `Hook: ` prefix lets
    /// `ToolResultView` render it as a card (see `isHookTool`).
    static func hookToolName(for hook: HookProfile) -> String {
        hookToolName(for: hook.name)
    }

    /// Card tool-name from a hook's display name. Used both live and when
    /// rebuilding a persisted hook card on reload.
    static func hookToolName(for name: String) -> String {
        "Hook: \(name.isEmpty ? "Untitled" : name)"
    }

    /// Rebuild the persisted "last hook" card and append it to a freshly-loaded
    /// message list so the hook stays visible after a reload. No-op when there's
    /// no stored hook or when the live list already contains that card (matched
    /// by its tool id), so an active-stream reconcile won't duplicate it.
    func messagesWithPersistedHookCard(_ messages: [ChatMessage], sessionId: String) -> [ChatMessage] {
        guard let record = threadStore.loadHookStatus(sessionId: sessionId) else { return messages }
        let alreadyPresent = messages.contains { message in
            message.blocks.contains { $0.toolCall?.id == record.toolId }
        }
        guard !alreadyPresent else { return messages }

        // A still-running record (e.g. a code review in flight) rebuilds as a
        // spinner: `result == nil` drives the "running" hook card in
        // `ToolResultView`. It's finalized live by `completeCard` (matched on
        // tool id) or swept to "interrupted" on the next launch.
        let toolCall = ToolCall(
            id: record.toolId,
            name: Self.hookToolName(for: record.name),
            input: [
                "name": .string(record.name),
                "trigger": .string(record.trigger),
            ],
            result: record.isComplete ? record.output : nil,
            isError: record.isError
        )
        var result = messages
        result.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            blocks: [.toolCall(toolCall)],
            isResponseComplete: record.isComplete,
            timestamp: record.updatedAt
        ))
        return result
    }

    // MARK: - Stop-hook auto-continue

    /// How many times a failing `beforeSessionStop` hook may auto-continue the
    /// agent for one session before we give up, so a perpetually-failing hook
    /// can't loop the agent forever.
    static let maxStopHookReprompts = 3

    /// Feed a failing before-session-stop hook's output back to the agent as a
    /// new turn so it can fix the reported problem (lint/test failures, …),
    /// mirroring Claude Code's blocking Stop hook. Bounded per session by
    /// `maxStopHookReprompts`. The counter resets when the hook next passes or
    /// when the user sends a real message (see `sendPrompt`).
    func repromptAfterStopHookFailure(output: String, project: Project, sessionKey: String) {
        let attempts = stopHookRepromptCounts[sessionKey, default: 0]
        guard attempts < Self.maxStopHookReprompts else {
            logger.warning("Stop-hook reprompt cap (\(Self.maxStopHookReprompts)) reached for session \(sessionKey, privacy: .public); not auto-continuing.")
            return
        }
        let attempt = attempts + 1
        stopHookRepromptCounts[sessionKey] = attempt

        let detail = output.isEmpty ? "(the hook exited non-zero but produced no output)" : output
        let prompt = """
        A "Before Session Stop" hook reported a failure (non-zero exit). Resolve the issues below, then finish:

        \(detail)
        """

        // Render the auto-continue as its own card (see `ToolResultView`'s
        // `isAutoContinueTool`) rather than a user bubble, so it reads as a
        // system action instead of something the user typed. The full prompt is
        // kept as the card's result so it stays inspectable.
        updateState(sessionKey) { state in
            let toolCall = ToolCall(
                id: UUID().uuidString,
                name: ToolCall.autoContinueToolName,
                input: [
                    "summary": .string("Before Session Stop hook failed — continuing (attempt \(attempt) of \(Self.maxStopHookReprompts)).")
                ],
                result: detail,
                isError: false
            )
            state.messages.append(ChatMessage(
                id: UUID(),
                role: .assistant,
                blocks: [.toolCall(toolCall)],
                isResponseComplete: true
            ))
        }

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionKey

        // `skipAppendingUserMessage` keeps the prompt out of the chat as a user
        // bubble — the card above represents it — while still sending it to the
        // agent so it actually continues.
        Task { [weak self] in
            await self?.sendPrompt(prompt, skipAppendingUserMessage: true, isStopHookReprompt: true, in: window)
        }
    }

    // MARK: - Code-review auto-fix

    /// How many times a failing code review may auto-continue the reviewed thread
    /// to fix the reported problems before we give up, so a never-passing review
    /// can't loop the agent forever.
    static let maxReviewFixReprompts = 3

    /// Feed a failing code review's feedback back into the reviewed thread as a
    /// new fix turn so the agent can address the reviewer's findings, then
    /// finish — at which point the Code Review hook runs again on the fixed
    /// change (fix → review → fix). Bounded per session by `maxReviewFixReprompts`.
    /// Returns the 1-based attempt number started, or `nil` if the cap was already
    /// reached (the caller surfaces a "stopped" card instead of looping). The
    /// counter resets when review passes or the user sends a real message (see
    /// `sendPrompt`). Mirrors `repromptAfterStopHookFailure`: rendered as an
    /// auto-continue card (not a user bubble) and sent with `isStopHookReprompt`
    /// so it doesn't reset its own loop counter.
    @discardableResult
    func repromptAfterReviewFailure(feedback: String, project: Project, sessionKey: String) -> Int? {
        let attempts = reviewRoundBySession[sessionKey, default: 0]
        guard attempts < Self.maxReviewFixReprompts else {
            logger.warning("Code-review auto-fix cap (\(Self.maxReviewFixReprompts)) reached for session \(sessionKey, privacy: .public); not auto-continuing.")
            return nil
        }
        let attempt = attempts + 1
        reviewRoundBySession[sessionKey] = attempt

        let detail = feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(the reviewer requested changes but gave no detail)"
            : feedback
        let prompt = """
        A code review of your change requested changes (REVIEW_RESULT: FAIL). Address the issues below, then finish:

        \(detail)
        """

        // Render the auto-continue as its own card (see `ToolResultView`'s
        // `isAutoContinueTool`) rather than a user bubble, so it reads as a
        // system action instead of something the user typed.
        updateState(sessionKey) { state in
            let toolCall = ToolCall(
                id: UUID().uuidString,
                name: ToolCall.autoContinueToolName,
                input: [
                    "summary": .string("Code review requested changes — continuing (attempt \(attempt) of \(Self.maxReviewFixReprompts)).")
                ],
                result: detail,
                isError: false
            )
            state.messages.append(ChatMessage(
                id: UUID(),
                role: .assistant,
                blocks: [.toolCall(toolCall)],
                isResponseComplete: true
            ))
        }

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionKey

        Task { [weak self] in
            await self?.sendPrompt(prompt, skipAppendingUserMessage: true, isStopHookReprompt: true, in: window)
        }
        return attempt
    }
}
