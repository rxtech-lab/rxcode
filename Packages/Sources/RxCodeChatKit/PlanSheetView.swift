import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit
import Combine

/// Test-only inspection emissary used by `PlanSheetView` so ViewInspector tests
/// can observe @State transitions (composer reveal, feedback text). At runtime
/// `notice` is never published, so `visit` is a no-op and the hook costs nothing.
public final class PlanSheetInspection: @unchecked Sendable {
    public let notice = PassthroughSubject<UInt, Never>()
    public var callbacks: [UInt: (PlanSheetView) -> Void] = [:]

    public init() {}

    public func visit(_ view: PlanSheetView, _ line: UInt) {
        if let callback = callbacks.removeValue(forKey: line) {
            callback(view)
        }
    }
}

/// Sheet UI for a Claude `ExitPlanMode` tool call. Shows the full plan markdown,
/// the five accept/reject decision buttons, and an inline feedback composer when
/// the user picks "Reject with Reason".
///
/// Closing the sheet via the X button, Esc, or clicking outside calls `onClose`,
/// which dismisses the UI but leaves the underlying `PendingPlan` in
/// `ChatBridge.pendingPlans`. The user can re-open the sheet from the
/// pending-plan banner above the input bar or by tapping the inline status
/// chip in the chat. Only the explicit decision buttons resolve the CLI hook.
public struct PlanSheetView: View {
    let plan: PendingPlan
    /// Number of additional pending plans queued behind this one (e.g. when the
    /// model emits multiple plans in close succession). Mirrors the
    /// "+N more pending" badge on `QuestionSheetView`.
    let remainingCount: Int
    let onSubmit: (_ toolCallId: String, _ action: PlanDecisionAction) -> Void
    /// Dismisses the sheet but leaves the plan in the pending queue so the user
    /// can re-open it from the banner later. Does NOT resolve the CLI hook.
    let onClose: () -> Void

    @State private var feedbackText: String
    @State private var isComposingFeedback: Bool
    @State private var isResolving: Bool = false

    // Test-only hook used by ViewInspector tests to observe @State transitions
    // (e.g. feedback composer reveal). Does nothing at runtime.
    internal let inspection = PlanSheetInspection()

    public init(
        plan: PendingPlan,
        remainingCount: Int,
        onSubmit: @escaping (_ toolCallId: String, _ action: PlanDecisionAction) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.init(
            plan: plan,
            remainingCount: remainingCount,
            initialFeedbackText: "",
            initialIsComposingFeedback: false,
            onSubmit: onSubmit,
            onClose: onClose
        )
    }

    /// Designated init with seams for `feedbackText`/`isComposingFeedback`. Tests
    /// use this to mount the sheet with the composer already revealed, which
    /// sidesteps a SwiftUI/ViewInspector double-free that triggers when the
    /// `decisionButtons → feedbackComposer` view swap happens inside a hosted
    /// view after a previous test already hosted+expelled a `PlanSheetView`.
    internal init(
        plan: PendingPlan,
        remainingCount: Int,
        initialFeedbackText: String,
        initialIsComposingFeedback: Bool,
        onSubmit: @escaping (_ toolCallId: String, _ action: PlanDecisionAction) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.plan = plan
        self.remainingCount = remainingCount
        self.onSubmit = onSubmit
        self.onClose = onClose
        self._feedbackText = State(initialValue: initialFeedbackText)
        self._isComposingFeedback = State(initialValue: initialIsComposingFeedback)
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView(.vertical) {
                planBody
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
        .background(ClaudeTheme.background)
        .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(ClaudeTheme.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Plan", bundle: .module)
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                if remainingCount > 0 {
                    Text(String(format: String(localized: "+%d more pending", bundle: .module), remainingCount))
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            Spacer()

            Button(action: copyMarkdown) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ClaudeTheme.surfaceSecondary))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Copy plan", bundle: .module))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ClaudeTheme.surfaceSecondary))
            }
            .buttonStyle(.plain)
            .disabled(isResolving)
            .help(String(localized: "Close — you can review later from the banner", bundle: .module))
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Body

    @ViewBuilder
    private var planBody: some View {
        if plan.markdown.isEmpty {
            Text("Plan content unavailable.", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        } else {
            MarkdownContentView(text: plan.markdown)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if plan.isDecided {
            decidedRow
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        } else if isComposingFeedback {
            feedbackComposer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        } else {
            decisionButtons
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }

    private var decidedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(ClaudeTheme.accent)
                .font(.system(size: 13, weight: .medium))
            Text(plan.decisionSummary ?? String(localized: "Decided", bundle: .module))
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
    }

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
        .disabled(isResolving)
        .opacity(isResolving ? 0.6 : 1.0)
    }

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

    // MARK: - Actions

    private func submitFeedback() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(.rejectWithFeedback(reason: trimmed))
    }

    private func submit(_ action: PlanDecisionAction) {
        guard !isResolving else { return }
        isResolving = true
        onSubmit(plan.toolCallId, action)
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plan.markdown, forType: .string)
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
        .accessibilityIdentifier("plan-button-\(accessibilityIDComponent(from: title))")
    }

    private func accessibilityIDComponent(from title: String) -> String {
        title
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
    }
}
#endif
