import Foundation
import os
import RxCodeChatKit
import RxCodeCore

/// Aggregate outcome of running every hook for one trigger. `combinedOutput`
/// is the concatenated stdout (used to inject start-hook context or to feed a
/// failing stop hook back to the agent); `hasError` is true if any hook exited
/// non-zero.
struct HookBatchResult: Sendable {
    let combinedOutput: String
    let hasError: Bool

    static let empty = HookBatchResult(combinedOutput: "", hasError: false)
}

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

    /// Run every enabled hook for `trigger`, inserting a live status card into
    /// the session's message list for each (running spinner → success/error +
    /// expandable output). Returns the hooks' combined stdout so a caller can
    /// inject it into the agent's context (used by `beforeSessionStart`).
    ///
    /// Inserting via `updateState` means the cards stream to paired mobile
    /// devices automatically. Whether the cards persist is up to the caller:
    /// start / before-stop hooks are followed by a `saveSession`; after-stop
    /// hooks are not, so their cards are shown but not saved ("nothing passed").
    @discardableResult
    func runHooks(
        trigger: HookTrigger,
        project: Project,
        sessionKey: String
    ) async -> HookBatchResult {
        await ensureHookProfilesLoaded(for: project.id)
        let hooks = hookProfiles(for: project.id).filter { $0.enabled && $0.trigger == trigger }
        guard !hooks.isEmpty else { return .empty }

        var combined: [String] = []
        var anyError = false
        for hook in hooks {
            let toolId = UUID().uuidString
            let messageId = UUID()
            let toolName = Self.hookToolName(for: hook)

            updateState(sessionKey) { state in
                let toolCall = ToolCall(
                    id: toolId,
                    name: toolName,
                    input: [
                        "name": .string(hook.name),
                        "trigger": .string(hook.trigger.displayName),
                    ],
                    result: nil
                )
                // Synthetic hook cards are NOT part of the agent's streaming
                // turn, so they must not carry `isStreaming`. A stop hook runs
                // after `finalizeStreamSession` has cleared the session-level
                // `isStreaming`; a trailing message flagged streaming while the
                // session is not makes `settledOnlyMessages` drop the whole last
                // assistant run (the real reply + this card) into a streaming
                // slice that never renders — both vanish. The "running" spinner
                // is driven by `result == nil` instead (see `ToolResultView`).
                state.messages.append(ChatMessage(
                    id: messageId,
                    role: .assistant,
                    blocks: [.toolCall(toolCall)],
                    isStreaming: false
                ))
            }

            let result = await HookService.run(hook, project: project)
            let displayOutput = result.output.isEmpty ? "(no output)" : result.output

            updateState(sessionKey) { state in
                guard let idx = state.messages.firstIndex(where: { $0.id == messageId }) else { return }
                state.messages[idx].setToolResult(id: toolId, result: displayOutput, isError: result.isError)
                state.messages[idx].isStreaming = false
                state.messages[idx].isResponseComplete = true
            }

            // Persist this hook as the session's "last hook" so its card can be
            // rebuilt on reload — hook cards are synthetic and never reach the
            // CLI transcript. Each hook overwrites the prior row, so the most
            // recent hook (across triggers) is the one that survives.
            threadStore.setHookStatus(
                sessionId: sessionKey,
                toolId: toolId,
                name: hook.name,
                trigger: hook.trigger.displayName,
                output: displayOutput,
                isError: result.isError
            )

            if result.isError { anyError = true }
            if !result.output.isEmpty {
                combined.append("### Hook: \(hook.name)\n\(result.output)")
            }
        }

        return HookBatchResult(combinedOutput: combined.joined(separator: "\n\n"), hasError: anyError)
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

        let toolCall = ToolCall(
            id: record.toolId,
            name: Self.hookToolName(for: record.name),
            input: [
                "name": .string(record.name),
                "trigger": .string(record.trigger),
            ],
            result: record.output,
            isError: record.isError
        )
        var result = messages
        result.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            blocks: [.toolCall(toolCall)],
            isResponseComplete: true,
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
}
