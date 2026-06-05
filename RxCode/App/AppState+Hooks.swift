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

    /// `locale` (language code) renders built-in titles for that language; nil =>
    /// the desktop's own locale (used by native menus). Mobile relay requests pass
    /// the phone's locale so titles come back translated.
    func projectContextMenuItems(for project: Project, branch: String? = nil, locale: String? = nil) -> [MenuItem] {
        // Touch the revision so SwiftUI re-runs this fetch (and thus picks up
        // newly created/edited custom items) when called from a view body.
        _ = customMenuItemsRevision
        return hookManager.projectContextMenuItems(ProjectContextMenuPayload(project: project, branch: branch, locale: locale))
    }

    func threadContextMenuItems(for session: ChatSession.Summary, locale: String? = nil) -> [MenuItem] {
        _ = customMenuItemsRevision
        guard let project = projects.first(where: { $0.id == session.projectId }) else { return [] }
        return hookManager.threadContextMenuItems(ThreadContextMenuPayload(project: project, session: session, locale: locale))
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

    /// Rebuild every persisted hook card for a session and merge them back into a
    /// freshly-loaded message list so the hooks stay visible after a reload — and
    /// at the position where they originally ran. Cards already present in the
    /// live list (matched by tool id) are skipped, so an active-stream reconcile
    /// won't duplicate them.
    ///
    /// The transcript renders in array order, so each card is inserted at its
    /// chronological spot by `createdAt` (loaded CLI messages carry real
    /// timestamps): a before-session-start card stays at the top, a between-turns
    /// card stays between turns, instead of every card jumping to the bottom.
    func messagesWithPersistedHookCard(_ messages: [ChatMessage], sessionId: String) -> [ChatMessage] {
        // Oldest first, so cards inserted in the same gap keep their relative order.
        let records = threadStore.loadHookCards(sessionId: sessionId)
        guard !records.isEmpty else { return messages }

        var result = messages
        for record in records {
            let alreadyPresent = result.contains { message in
                message.blocks.contains { $0.toolCall?.id == record.toolId }
            }
            guard !alreadyPresent else { continue }

            // A still-running record (e.g. a code review in flight) rebuilds as a
            // spinner: `result == nil` drives the "running" hook card in
            // `ToolResultView`. It's finalized live by `completeCard` (matched on
            // tool id) or swept to "interrupted" on the next launch.
            let input = (try? JSONDecoder().decode([String: JSONValue].self, from: record.inputData)) ?? [:]
            let toolCall = ToolCall(
                id: record.toolId,
                name: record.toolName,
                input: input,
                result: record.isComplete ? record.result : nil,
                isError: record.isError
            )
            let card = ChatMessage(
                id: UUID(),
                role: .assistant,
                blocks: [.toolCall(toolCall)],
                isResponseComplete: record.isComplete,
                timestamp: record.createdAt
            )
            // Insert after the last message at or before the card's insertion
            // time. Already-placed earlier cards (smaller `createdAt`) sort ahead
            // of this one, so same-gap cards stay in insertion order.
            let insertionIndex = result.firstIndex { $0.timestamp > record.createdAt } ?? result.endIndex
            result.insert(card, at: insertionIndex)
        }
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
        let toolId = UUID().uuidString
        let summary: [String: JSONValue] = [
            "summary": .string("Before Session Stop hook failed — continuing (attempt \(attempt) of \(Self.maxStopHookReprompts)).")
        ]
        updateState(sessionKey) { state in
            let toolCall = ToolCall(
                id: toolId,
                name: ToolCall.autoContinueToolName,
                input: summary,
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
        // Persist so the auto-continue card survives an app reload (it's
        // synthetic and never reaches the CLI transcript).
        threadStore.upsertHookCard(
            sessionId: sessionKey,
            toolId: toolId,
            toolName: ToolCall.autoContinueToolName,
            input: summary,
            result: detail,
            isError: false,
            isComplete: true
        )

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
        let toolId = UUID().uuidString
        let summary: [String: JSONValue] = [
            "summary": .string("Code review requested changes — continuing (attempt \(attempt) of \(Self.maxReviewFixReprompts)).")
        ]
        updateState(sessionKey) { state in
            let toolCall = ToolCall(
                id: toolId,
                name: ToolCall.autoContinueToolName,
                input: summary,
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
        // Persist so the auto-continue card survives an app reload (it's
        // synthetic and never reaches the CLI transcript).
        threadStore.upsertHookCard(
            sessionId: sessionKey,
            toolId: toolId,
            toolName: ToolCall.autoContinueToolName,
            input: summary,
            result: detail,
            isError: false,
            isComplete: true
        )

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionKey

        Task { [weak self] in
            await self?.sendPrompt(prompt, skipAppendingUserMessage: true, isStopHookReprompt: true, in: window)
        }
        return attempt
    }
}
