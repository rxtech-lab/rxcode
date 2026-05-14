import SwiftUI
import ClarcCore
import AppKit

/// Interactive UI for a Claude `ExitPlanMode` tool call, plus a fallback for plan
/// markdown files written via `Write` to `~/.claude/plans/*.md`. Renders the plan as
/// rich markdown and (when pending) shows action buttons for the user to accept
/// or reject the plan.
struct PlanCardView: View {
    let toolCall: ToolCall
    let planMarkdown: String
    let isMessageStreaming: Bool
    /// Fallback plan markdown sourced from prior assistant messages — used when the
    /// current `ExitPlanMode` call has no inline `plan` content (e.g. the model wrote
    /// the plan to `~/.claude/plans/*.md` in a previous turn before an
    /// `AskUserQuestion` split the assistant run).
    var externalPlanMarkdown: String? = nil

    @Environment(WindowState.self) private var windowState

    // Match the summary strings written by AppState.respondToPlanDecision. Any other
    // non-nil result (e.g., CLI-side "Exit plan mode?" responses) must not be treated
    // as a user decision, otherwise the accept/reject buttons get hidden before the
    // user has actually clicked one.
    static let userDecisionPrefixes: [String] = [
        "Accepted with Ask",
        "Accepted with Edits",
        "Accepted with Auto-approve",
        "Rejected",
    ]

    static func isPlanDecided(_ toolCall: ToolCall) -> Bool {
        guard let result = toolCall.result else { return false }
        return userDecisionPrefixes.contains { result.hasPrefix($0) }
    }

    @State private var isExpanded: Bool = true
    @State private var showFullSheet: Bool = false
    @State private var feedbackText: String = ""
    @State private var isComposingFeedback: Bool = false
    @State private var isResolving: Bool = false

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
        if let text = block.text {
            return hasExitPlanInMessage && isPlanReadyFollowup(text)
        }
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
    /// cards when the model re-emits a fresh plan — only the latest is actionable.
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

    private var isDecided: Bool {
        Self.isPlanDecided(toolCall)
    }

    private var isStreaming: Bool {
        // Spinner only while the parent assistant message is still streaming AND no
        // plan content has arrived yet (including a prior-turn fallback). Once the
        // message stops streaming, drop the spinner even if planMarkdown is still
        // empty — otherwise the card stays stuck when input_json_delta never arrives
        // or the parsed input lacks a `plan` key.
        guard isMessageStreaming else { return false }
        if !planMarkdown.isEmpty { return false }
        if let external = externalPlanMarkdown, !external.isEmpty { return false }
        return true
    }

    private var resolvedMarkdown: String {
        if !planMarkdown.isEmpty { return planMarkdown }
        return externalPlanMarkdown ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                planBody

                if isExitPlanMode {
                    decisionArea
                }
            } else {
                collapsedPreview
            }
        }
        .bubbleStyle(.tool)
        .sheet(isPresented: $showFullSheet) {
            PlanFullSheet(markdown: resolvedMarkdown)
        }
        .onChange(of: isDecided) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 16, height: 16)

            Text("Plan", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)

            Spacer()

            if isDecided {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                    .font(.caption)
            }

            headerIconButton(
                systemName: "doc.on.doc",
                help: String(localized: "Copy plan", bundle: .module)
            ) {
                copyMarkdown()
            }

            headerIconButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                help: String(localized: "Open in full window", bundle: .module)
            ) {
                showFullSheet = true
            }

            headerIconButton(
                systemName: isExpanded ? "chevron.up" : "chevron.down",
                help: String(localized: isExpanded ? "Collapse" : "Expand", bundle: .module)
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            }
        }
    }

    @ViewBuilder
    private func headerIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Body

    @ViewBuilder
    private var planBody: some View {
        if isStreaming {
            // Avoid markdown flicker while input_json_delta is still streaming — show
            // a lightweight placeholder until the tool call completes.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Drafting plan…", bundle: .module)
                    .font(.system(size: ClaudeTheme.messageSize(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            .padding(.vertical, 4)
        } else if resolvedMarkdown.isEmpty {
            Text("Plan content unavailable.", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .padding(.vertical, 4)
        } else {
            MarkdownContentView(text: resolvedMarkdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var collapsedPreview: some View {
        let firstLine = resolvedMarkdown
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            ?? "(empty plan)"
        VStack(alignment: .leading, spacing: 4) {
            Text(firstLine)
                .font(.system(size: ClaudeTheme.messageSize(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if isDecided, let summary = toolCall.result, !summary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(ClaudeTheme.accent)
                        .font(.system(size: 10, weight: .medium))
                    Text(summary)
                        .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // MARK: - Decision Area

    @ViewBuilder
    private var decisionArea: some View {
        if isDecided {
            decidedRow
        } else if isComposingFeedback {
            feedbackComposer
        } else if !isStreaming {
            decisionButtons
        }
    }

    @ViewBuilder
    private var decidedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(ClaudeTheme.accent)
                .font(.system(size: 11, weight: .medium))
            Text(toolCall.result ?? "Decided")
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(2)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var decisionButtons: some View {
        VStack(spacing: 8) {
            planButton(
                title: String(localized: "Accept + Auto", bundle: .module),
                systemImage: "wand.and.sparkles",
                style: .primary,
                fullWidth: true
            ) {
                submit(.acceptAutoApprove)
            }

            planButton(
                title: String(localized: "Accept Edits", bundle: .module),
                systemImage: "pencil.tip.crop.circle.badge.checkmark",
                style: .secondary,
                fullWidth: true
            ) {
                submit(.acceptWithEdits)
            }

            planButton(
                title: String(localized: "Accept Ask", bundle: .module),
                systemImage: "bolt.shield",
                style: .secondary,
                fullWidth: true
            ) {
                submit(.acceptAsk)
            }

            planButton(
                title: String(localized: "Reject with Reason", bundle: .module),
                systemImage: "text.bubble",
                style: .secondary,
                fullWidth: true
            ) {
                feedbackText = ""
                withAnimation(.easeInOut(duration: 0.18)) { isComposingFeedback = true }
            }

            planButton(
                title: String(localized: "Reject", bundle: .module),
                systemImage: "xmark.circle",
                style: .secondary,
                fullWidth: true
            ) {
                submit(.reject)
            }
        }
        .padding(.top, 4)
        .disabled(isResolving)
        .opacity(isResolving ? 0.6 : 1.0)
    }

    @ViewBuilder
    private var feedbackComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell Claude what to change", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)

            TextField(
                String(localized: "What would you like changed?", bundle: .module),
                text: $feedbackText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .font(.system(size: ClaudeTheme.messageSize(13)))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 1)
            )
            .onSubmit { submitFeedback() }

            HStack(spacing: 8) {
                planButton(
                    title: String(localized: "Cancel", bundle: .module),
                    systemImage: "arrow.uturn.backward",
                    style: .secondary
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) { isComposingFeedback = false }
                }
                Spacer()
                planButton(
                    title: String(localized: "Send feedback", bundle: .module),
                    systemImage: "paperplane.fill",
                    style: .primary,
                    isDisabled: feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    submitFeedback()
                }
            }
        }
        .disabled(isResolving)
        .opacity(isResolving ? 0.6 : 1.0)
    }

    private func submitFeedback() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(.rejectWithFeedback(reason: trimmed))
    }

    private func submit(_ action: PlanDecisionAction) {
        guard !isResolving else { return }
        isResolving = true
        windowState.planDecisionHandler?(toolCall.id, action)
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resolvedMarkdown, forType: .string)
    }

    // MARK: - Button helper

    private enum PlanButtonStyle { case primary, secondary }

    @ViewBuilder
    private func planButton(
        title: String,
        systemImage: String,
        style: PlanButtonStyle,
        isDisabled: Bool = false,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(style == .primary ? Color.white : ClaudeTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                style == .primary
                    ? ClaudeTheme.accent
                    : ClaudeTheme.surfaceSecondary
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        style == .primary ? Color.clear : ClaudeTheme.borderSubtle,
                        lineWidth: 1
                    )
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Full Sheet

private struct PlanFullSheet: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Plan", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(markdown, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Copy", bundle: .module))

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close", bundle: .module))
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(ClaudeTheme.surfaceSecondary)

            Divider()

            ScrollView(.vertical) {
                MarkdownContentView(text: markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
    }
}
