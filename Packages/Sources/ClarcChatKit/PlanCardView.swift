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

    @Environment(WindowState.self) private var windowState

    // Match the summary strings written by AppState.respondToPlanDecision. Any other
    // non-nil result (e.g., CLI-side "Exit plan mode?" responses) must not be treated
    // as a user decision, otherwise the accept/reject buttons get hidden before the
    // user has actually clicked one.
    private static let userDecisionPrefixes: [String] = [
        "Accepted with Ask",
        "Accepted with Edits",
        "Accepted with Auto-approve",
        "Rejected",
    ]

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

    static func shouldHideBlock(_ block: MessageBlock, in message: ChatMessage) -> Bool {
        let hasExitPlan = containsExitPlanMode(message)
        if let text = block.text {
            return hasExitPlan && isPlanReadyFollowup(text)
        }
        guard hasExitPlan, let toolCall = block.toolCall else { return false }
        return isPlanFileWrite(toolCall)
    }

    private var isExitPlanMode: Bool {
        Self.isExitPlanMode(toolCall)
    }

    private var isDecided: Bool {
        // Only treat the card as decided when the result matches one of the summary
        // strings written by AppState.respondToPlanDecision. The CLI itself can leave
        // unrelated text (e.g. "Exit plan mode?") in `toolCall.result` before the user
        // has picked anything; that must not hide the accept/reject buttons.
        guard let result = toolCall.result else { return false }
        return Self.userDecisionPrefixes.contains { result.hasPrefix($0) }
    }

    private var isStreaming: Bool {
        // Spinner only while the parent assistant message is still streaming AND no
        // plan content has arrived yet. Once the message stops streaming, drop the
        // spinner even if planMarkdown is still empty — otherwise the card stays stuck
        // when input_json_delta never arrives or the parsed input lacks a `plan` key.
        isMessageStreaming && planMarkdown.isEmpty
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
            PlanFullSheet(markdown: planMarkdown)
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
        } else if planMarkdown.isEmpty {
            Text("Plan content unavailable.", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .padding(.vertical, 4)
        } else {
            MarkdownContentView(text: planMarkdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var collapsedPreview: some View {
        let firstLine = planMarkdown
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            ?? "(empty plan)"
        Text(firstLine)
            .font(.system(size: ClaudeTheme.messageSize(12)))
            .foregroundStyle(ClaudeTheme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
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
        pasteboard.setString(planMarkdown, forType: .string)
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
