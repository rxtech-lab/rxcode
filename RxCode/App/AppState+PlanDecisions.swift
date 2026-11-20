import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Plan Decision Response

    /// Resolve a Claude `ExitPlanMode` tool call based on the user's choice in the plan card.
    /// Drives both the PermissionServer hook response (allow/deny + optional reason or
    /// follow-up mode change) and the local UI bookkeeping (clear plan-mode pill, update
    /// permission chip, mark the tool block decided).
    func respondToPlanDecision(toolUseId: String, action: PlanDecisionAction, in window: WindowState) async {
        let summary: String
        let decision: PermissionDecision
        let nextMode: PermissionMode?
        // Whether this decision moves the session out of plan mode. Only an
        // *accept* does — the user has approved a plan and is ready to implement.
        // A reject (with or without feedback) keeps the user in the planning
        // phase: the model will revise and re-emit `ExitPlanMode`, and that next
        // plan must launch with `--permission-mode plan` so the CLI actually
        // pauses for the plan card instead of auto-resolving it with the
        // "Exit plan mode?" placeholder (which leaves the user having to
        // manually re-chat to make any decision stick).
        let exitsPlanMode: Bool

        switch action {
        case .acceptAsk:
            summary = "Accepted with Ask"
            decision = .allowAndSetMode(newMode: .default)
            nextMode = .default
            exitsPlanMode = true
        case .acceptWithEdits:
            summary = "Accepted with Edits"
            decision = .allowAndSetMode(newMode: .acceptEdits)
            nextMode = .acceptEdits
            exitsPlanMode = true
        case .acceptAutoApprove:
            summary = "Accepted with Auto-approve"
            decision = .allowAndSetMode(newMode: .auto)
            nextMode = .auto
            exitsPlanMode = true
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            summary = trimmed.isEmpty ? "Rejected" : "Rejected: \(trimmed)"
            decision = .denyWithReason(reason: trimmed.isEmpty ? "User rejected the plan." : trimmed)
            nextMode = nil
            exitsPlanMode = false
        case .reject:
            summary = "Rejected"
            decision = .denyWithReason(reason: "User rejected the plan.")
            nextMode = nil
            exitsPlanMode = false
        }

        // Record the outcome on the tool block so `PlanCardView` flips from buttons to
        // a "decided" status row. This mirrors how AskUserQuestionView reads `toolCall.result`.
        // Also write into a sidecar dict that survives CLI-backed session reloads —
        // the CLI emits its own follow-up tool_result ("User has approved your plan…")
        // that overwrites `ToolCall.result` once the session jsonl is parsed fresh
        // from disk, so the in-memory result alone is not reliable.
        let key = window.currentSessionId ?? window.newSessionKey
        updateState(key) { state in
            for i in state.messages.indices.reversed() {
                if state.messages[i].toolCallIndex(id: toolUseId) != nil {
                    state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                    break
                }
            }
            state.planDecisionSummaries[toolUseId] = summary
        }
        threadStore.setPlanDecision(sessionId: key, toolCallId: toolUseId, summary: summary)

        // Clear the plan-mode pill only when the user accepted — that's the
        // transition out of planning and into implementation. On a reject we stay
        // in plan mode so the revised plan re-enters the real ExitPlanMode pause
        // (see `exitsPlanMode` above). The mode re-register below runs regardless.
        if exitsPlanMode, window.sessionPlanMode {
            window.sessionPlanMode = false
            updateState(key) { $0.planMode = false }
        }

        // Persist the new permission mode in the dropdown when the user opted for a
        // follow-up mode change. `setSessionPermissionMode` also re-registers with the
        // PermissionServer for the live session.
        if let nextMode {
            setSessionPermissionMode(nextMode, in: window)
        } else {
            // Even when no mode change is requested, re-register so the server registry
            // reflects the now-cleared plan-mode boolean.
            reregisterPermissionMode(in: window)
        }

        let autoResolvedIds = await permission.respond(toolUseId: toolUseId, decision: decision)
        clearAutoResolvedPermissions(autoResolvedIds)

        // Fan the plan decision out to hooks (one site → fires once for desktop + mobile).
        switch action {
        case .acceptAsk:
            await hookManager.dispatchPlanAccept(PlanAcceptPayload(toolUseId: toolUseId, sessionKey: key, mode: "ask"))
        case .acceptWithEdits:
            await hookManager.dispatchPlanAccept(PlanAcceptPayload(toolUseId: toolUseId, sessionKey: key, mode: "acceptEdits"))
        case .acceptAutoApprove:
            await hookManager.dispatchPlanAccept(PlanAcceptPayload(toolUseId: toolUseId, sessionKey: key, mode: "auto"))
        case .reject:
            await hookManager.dispatchPlanReject(PlanRejectPayload(toolUseId: toolUseId, sessionKey: key, reason: nil))
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            await hookManager.dispatchPlanReject(PlanRejectPayload(toolUseId: toolUseId, sessionKey: key, reason: trimmed.isEmpty ? nil : trimmed))
        }

        // When the CLI honors `allowAndSetMode` it continues the same turn — the model
        // executes (or revises) the plan inline and the turn ends naturally. In that
        // case sending a follow-up prompt would spawn a redundant second turn that
        // reports "the work is already done". Only inject a continuation message when
        // the turn actually ended without producing any post-plan content, mirroring
        // the older CLI behavior where ExitPlanMode terminated the turn outright.
        let continuationPrompt = Self.continuationPrompt(for: action)

        if let continuationPrompt {
            if let task = sessionStates[key]?.streamTask {
                _ = await task.value
            }
            if turnContinuedAfterPlan(toolUseId: toolUseId, sessionKey: key) {
                return
            }
            await sendPrompt(
                continuationPrompt,
                skipAppendingUserMessage: true,
                in: window
            )
        }
    }

    /// True when the assistant actually *executed* the plan after the given
    /// ExitPlanMode tool call — i.e. the CLI invoked at least one other tool
    /// (Edit / Write / Bash / etc.) in the same turn, so a follow-up
    /// "Proceed with the plan." would just spawn a redundant turn. Used to
    /// gate the hidden continuation prompt.
    ///
    /// Text-only post-plan content (a brief preamble, or a recap of the plan
    /// the model already wrote into a file) does NOT count — that's the stall
    /// mode where the user is left waiting and we *do* want to inject the
    /// nudge so implementation actually starts.
    func turnContinuedAfterPlan(toolUseId: String, sessionKey: String) -> Bool {
        guard let messages = sessionStates[sessionKey]?.messages else { return false }
        for messageIdx in messages.indices.reversed() {
            guard let planBlockIdx = messages[messageIdx].toolCallIndex(id: toolUseId) else {
                continue
            }
            // Same message: any *implementation* tool-call block after the plan block
            // counts as work.
            let trailingBlocks = messages[messageIdx].blocks.dropFirst(planBlockIdx + 1)
            if trailingBlocks.contains(where: Self.isImplementationToolCall) {
                return true
            }
            // Subsequent assistant messages: any implementation tool-call block at all.
            if messageIdx + 1 < messages.count {
                for later in messages[(messageIdx + 1)...] where later.role == .assistant {
                    if later.blocks.contains(where: Self.isImplementationToolCall) {
                        return true
                    }
                }
            }
            return false
        }
        return false
    }

    /// True when a block is a tool call that represents actual plan *execution*
    /// rather than plan *scaffolding*. Re-writing the plan into a
    /// `~/.claude/plans/*.md` file, or re-emitting `ExitPlanMode`, is the model
    /// restating the plan — not implementing it — and must not be mistaken for
    /// "the turn continued", otherwise the "Proceed with the plan." nudge is
    /// suppressed and the user is left having to re-prompt manually.
    private static func isImplementationToolCall(_ block: MessageBlock) -> Bool {
        guard let call = block.toolCall else { return false }
        if isExitPlanModeCall(call) { return false }
        if PlanLogic.isPlanFileWrite(call) { return false }
        return true
    }

    /// Prefixes of result strings written by `respondToPlanDecision`. Sourced from
    /// `PlanDecisionAction.userDecisionResultPrefixes` so the chip in chat, the
    /// CLI-session reload guard, and the live-stream guard all share one source
    /// of truth.
    static let planDecisionResultPrefixes: [String] = PlanDecisionAction.userDecisionResultPrefixes

    static func isExitPlanModeCall(_ call: ToolCall) -> Bool {
        let n = call.name.lowercased()
        return n == "exitplanmode" || n == "exit_plan_mode"
    }

    /// Hidden follow-up prompt to send after a plan decision, or nil if the chat
    /// should stop. Plain `.reject` returns nil; `.rejectWithFeedback` with empty
    /// feedback also returns nil (the user effectively did a plain reject).
    static func continuationPrompt(for action: PlanDecisionAction) -> String? {
        switch action {
        case .acceptAsk, .acceptWithEdits, .acceptAutoApprove:
            return "Proceed with the plan."
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? nil
                : "Revise the plan based on this feedback: \(trimmed)"
        case .reject:
            return nil
        }
    }
}
