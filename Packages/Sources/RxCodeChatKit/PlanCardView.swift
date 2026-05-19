import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit

/// Compact inline status chip for a Claude `ExitPlanMode` tool call. Replaces the
/// full markdown card that used to render here — the markdown body and decision
/// buttons now live in `PlanSheetView`, opened by tapping the chip or the
/// pending-plan banner above the input bar. The chip itself only communicates
/// the basic status: "Plan ready" while pending, the decision summary once
/// resolved, or a streaming placeholder while the call is still arriving.
///
/// The static helpers on this type are reused by `MessageBubble`,
/// `ChatBridge.pendingPlans`, and `AppState` to identify and de-duplicate plan
/// blocks across the chat history. They are unchanged from the original card.
struct PlanCardView: View {
    let toolCall: ToolCall
    let planMarkdown: String
    let isMessageStreaming: Bool
    /// Fallback plan markdown sourced from prior assistant messages — used when the
    /// current `ExitPlanMode` call has no inline `plan` content (e.g. the model wrote
    /// the plan to `~/.claude/plans/*.md` in a previous turn before an
    /// `AskUserQuestion` split the assistant run).
    var externalPlanMarkdown: String? = nil
    /// Optional override for the chip's tap behavior. When nil (production
    /// default), the chip writes `toolCall.id` to `windowState.presentedPlanToolCallId`
    /// to open the plan sheet. Tests inject a closure to capture the tap without
    /// needing the SwiftUI environment.
    var onOpen: ((String) -> Void)? = nil

    @Environment(WindowState.self) private var windowState
    /// Optional so isolated test mounts (without a ChatBridge ancestor) don't
    /// fatal on env lookup. Production hosts always inject one.
    @Environment(ChatBridge.self) private var chatBridge: ChatBridge?
    @State private var isHovered: Bool = false

    // Match the summary strings written by AppState.respondToPlanDecision. Any other
    // non-nil result (e.g., CLI-side "Exit plan mode?" responses) must not be treated
    // as a user decision, otherwise the chip flips to "decided" before the user has
    // actually clicked anything.
    static let userDecisionPrefixes: [String] = PlanDecisionAction.userDecisionResultPrefixes

    static func isPlanDecided(_ toolCall: ToolCall) -> Bool {
        guard let result = toolCall.result else { return false }
        return PlanDecisionAction.isUserDecisionResult(result)
    }

    init(
        toolCall: ToolCall,
        planMarkdown: String,
        isMessageStreaming: Bool,
        externalPlanMarkdown: String? = nil,
        onOpen: ((String) -> Void)? = nil
    ) {
        self.toolCall = toolCall
        self.planMarkdown = planMarkdown
        self.isMessageStreaming = isMessageStreaming
        self.externalPlanMarkdown = externalPlanMarkdown
        self.onOpen = onOpen
    }

    /// Extract the plan markdown for a tool call, or nil if this isn't a plan-bearing call.
    /// Routed from `MessageBubble` — when nil, the generic `ToolResultView` is used instead.
    static func planMarkdown(from toolCall: ToolCall) -> String? {
        if isExitPlanMode(toolCall) {
            return toolCall.input["plan"]?.stringValue
        }
        if isPlanFileWrite(toolCall) {
            return toolCall.input["content"]?.stringValue
        }
        return nil
    }

    static func isExitPlanMode(_ toolCall: ToolCall) -> Bool {
        let n = toolCall.name.lowercased()
        return n == "exitplanmode" || n == "exit_plan_mode"
    }

    static func isPlanFileWrite(_ toolCall: ToolCall) -> Bool {
        guard toolCall.name.lowercased() == "write",
              let path = toolCall.input["file_path"]?.stringValue,
              path.hasSuffix(".md") else {
            return false
        }
        return path.contains("/.claude/plans/") || path.contains("/claude/plans/")
    }

    static func isPlanReadyFollowup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Plan is ready at ") else { return false }
        return trimmed.contains(".md")
    }

    static func containsExitPlanMode(_ message: ChatMessage) -> Bool {
        message.blocks.contains { block in
            guard let toolCall = block.toolCall else { return false }
            return isExitPlanMode(toolCall)
        }
    }

    static func fallbackPlanMarkdown(in message: ChatMessage) -> String? {
        let markdowns: [String] = message.blocks.compactMap { block -> String? in
            guard let toolCall = block.toolCall, isPlanFileWrite(toolCall) else { return nil }
            return planMarkdown(from: toolCall)
        }
        return markdowns.last
    }

    /// Walk backwards from the message immediately before `message`, returning the
    /// most recent non-empty plan markdown written via `Write` to a `~/.claude/plans/*.md`
    /// file. Used as a cross-message fallback for `ExitPlanMode` cards whose own
    /// `plan` input is empty (typically because an `AskUserQuestion` split the
    /// assistant run and the model relied on the prior file write).
    static func latestPriorPlanMarkdown(before message: ChatMessage, in messages: [ChatMessage]) -> String? {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        for prior in messages[..<idx].reversed() {
            if let md = fallbackPlanMarkdown(in: prior), !md.isEmpty {
                return md
            }
        }
        return nil
    }

    static func containsPlanFileWrite(_ message: ChatMessage) -> Bool {
        message.blocks.contains { block in
            guard let toolCall = block.toolCall else { return false }
            return isPlanFileWrite(toolCall)
        }
    }

    static func isPurePlanFileWriteMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant,
              !message.isError,
              !message.isCompactBoundary,
              !message.isStreaming,
              !message.blocks.isEmpty else {
            return false
        }

        return message.blocks.allSatisfy { block in
            guard let toolCall = block.toolCall else { return false }
            return isPlanFileWrite(toolCall)
        }
    }

    static func renderMarkdown(for toolCall: ToolCall, in message: ChatMessage) -> String? {
        if isExitPlanMode(toolCall) {
            let markdown = toolCall.input["plan"]?.stringValue ?? ""
            return markdown.isEmpty ? (fallbackPlanMarkdown(in: message) ?? markdown) : markdown
        }
        return planMarkdown(from: toolCall)
    }

    static func shouldHideBlock(
        _ block: MessageBlock,
        in message: ChatMessage,
        allMessages: [ChatMessage] = []
    ) -> Bool {
        let hasExitPlanInMessage = containsExitPlanMode(message)
        // Text blocks (including the model's "Plan is ready at /path/foo.md"
        // follow-up) are intentionally NOT hidden — they render alongside the
        // plan card so the user sees the summary while approval is pending.
        if block.text != nil { return false }
        guard let toolCall = block.toolCall, isPlanFileWrite(toolCall) else { return false }
        // Hide a plan-file Write when the ExitPlanMode card is present anywhere in
        // the same assistant run — not just in this exact message. Two cards otherwise
        // appear when the model splits "write plan.md" and "ExitPlanMode" across
        // sibling messages within one turn.
        return hasExitPlanInMessage || assistantRunContainsExitPlanMode(after: message, in: allMessages)
    }

    /// True if any message in the same assistant run as `message` contains an
    /// `ExitPlanMode` tool call. An assistant run is a maximal sequence of
    /// assistant messages bounded by user messages on either side.
    private static func assistantRunContainsExitPlanMode(
        after message: ChatMessage,
        in allMessages: [ChatMessage]
    ) -> Bool {
        guard let idx = allMessages.firstIndex(where: { $0.id == message.id }) else { return false }
        // Scan forward to the next user message — a later sibling assistant message
        // can carry the ExitPlanMode card.
        for i in (idx + 1)..<allMessages.count {
            let m = allMessages[i]
            if m.role == .user { break }
            if containsExitPlanMode(m) { return true }
        }
        // Scan backward to the previous user message — covers the (rare) ordering
        // where ExitPlanMode arrives before the plan-file Write in the same run.
        if idx > 0 {
            for i in stride(from: idx - 1, through: 0, by: -1) {
                let m = allMessages[i]
                if m.role == .user { break }
                if containsExitPlanMode(m) { return true }
            }
        }
        return false
    }

    /// True if this `ExitPlanMode` tool call is followed by another `ExitPlanMode`
    /// in the same assistant run (no user message between). Used to hide stale plan
    /// chips when the model re-emits a fresh plan — only the latest is actionable.
    static func isSupersededExitPlanMode(
        toolCall: ToolCall,
        in message: ChatMessage,
        allMessages: [ChatMessage]
    ) -> Bool {
        guard isExitPlanMode(toolCall) else { return false }
        guard let msgIdx = allMessages.firstIndex(where: { $0.id == message.id }) else { return false }

        var sawSelf = false
        for i in msgIdx..<allMessages.count {
            let m = allMessages[i]
            if i > msgIdx, m.role == .user { return false }
            for block in m.blocks {
                guard let tc = block.toolCall, isExitPlanMode(tc) else { continue }
                if tc.id == toolCall.id { sawSelf = true; continue }
                if sawSelf { return true }
            }
        }
        return false
    }

    private var isExitPlanMode: Bool {
        Self.isExitPlanMode(toolCall)
    }

    /// Decision summary sourced first from the persisted sidecar dict (survives
    /// CLI-backed reloads), then falling back to `toolCall.result` for the
    /// brief in-flight window before the persisted value has been read back
    /// (and for non-CLI sessions where the dict is empty).
    private var persistedDecisionSummary: String? {
        if let s = chatBridge?.planDecisionSummaries[toolCall.id] { return s }
        guard let result = toolCall.result,
              PlanDecisionAction.isUserDecisionResult(result) else { return nil }
        return result
    }

    private var isDecided: Bool {
        persistedDecisionSummary != nil
    }

    private var resolvedMarkdown: String {
        if !planMarkdown.isEmpty { return planMarkdown }
        return externalPlanMarkdown ?? ""
    }

    private var isStreaming: Bool {
        guard isMessageStreaming else { return false }
        return resolvedMarkdown.isEmpty
    }

    var body: some View {
        Button(action: openSheet) {
            HStack(spacing: 8) {
                statusIcon
                statusText
                Spacer(minLength: 8)
                if !isStreaming {
                    Text(actionLabel)
                        .font(.system(size: ClaudeTheme.messageSize(11), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(ClaudeTheme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDecided ? ClaudeTheme.surfaceSecondary : ClaudeTheme.accentSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDecided
                            ? ClaudeTheme.borderSubtle
                            : ClaudeTheme.accent.opacity(isHovered ? 0.55 : 0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .onHover { isHovered = $0 }
        .disabled(isStreaming)
        .help(helpText)
        .accessibilityIdentifier("plan-card-button")
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isStreaming {
            ProgressView().controlSize(.small)
        } else if isDecided {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.accent)
        } else {
            Image(systemName: "doc.text.fill")
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.accent)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if isStreaming {
            Text("Drafting plan…", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        } else if let summary = persistedDecisionSummary, !summary.isEmpty {
            Text(summary)
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("Plan ready", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
    }

    private var actionLabel: String {
        isDecided
            ? String(localized: "View", bundle: .module)
            : String(localized: "Review", bundle: .module)
    }

    private var helpText: String {
        if isStreaming {
            return String(localized: "Plan is still drafting…", bundle: .module)
        }
        if isDecided {
            return String(localized: "Open the plan to review the decision", bundle: .module)
        }
        return String(localized: "Open the plan to accept or reject", bundle: .module)
    }

    private func openSheet() {
        guard !isStreaming else { return }
        if let onOpen {
            onOpen(toolCall.id)
        } else {
            windowState.presentedPlanToolCallId = toolCall.id
        }
    }
}
#endif
