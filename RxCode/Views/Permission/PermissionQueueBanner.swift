import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// Compact pill displayed directly above the chat input bar whenever the CLI
/// has pending permission requests, pending `AskUserQuestion` calls, or
/// undecided `ExitPlanMode` plans. Tapping it surfaces the corresponding
/// modal/sheet for the first queued item — streaming/typing is never
/// interrupted until the user explicitly opens it.
struct PermissionQueueBanner: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge
    @State private var isHovered: Bool = false

    private var pendingRequests: [PermissionRequest] {
        windowState.pendingPermissions.filter { $0.sessionId == windowState.currentSessionId }
    }

    private var questionCount: Int {
        pendingRequests.filter { $0.toolName == "AskUserQuestion" }.count
    }

    private var permissionCount: Int {
        pendingRequests.count - questionCount
    }

    /// Plans awaiting a user decision. Decided plans are excluded (they only show
    /// as the inline status chip in chat) and so are still-streaming plans whose
    /// markdown hasn't arrived yet — surfacing those would let the user "Review"
    /// an empty plan.
    private var pendingPlans: [PendingPlan] {
        chatBridge.pendingPlans.filter { !$0.isDecided && !$0.isStreaming }
    }

    private var planCount: Int { pendingPlans.count }

    private var totalCount: Int {
        pendingRequests.count + planCount
    }

    private var isEmpty: Bool { totalCount == 0 }

    private var bannerIcon: String {
        if planCount > 0 && permissionCount == 0 && questionCount == 0 {
            return "doc.text.fill"
        }
        if permissionCount > 0 {
            return "exclamationmark.shield.fill"
        }
        return "questionmark.circle.fill"
    }

    private var bannerText: String {
        // Single-category messaging when only one kind is pending.
        if planCount > 0, permissionCount == 0, questionCount == 0 {
            return countText(planCount, singular: "plan pending", plural: "plans pending")
        }
        if questionCount > 0, permissionCount == 0, planCount == 0 {
            return countText(questionCount, singular: "question pending", plural: "questions pending")
        }
        if permissionCount > 0, questionCount == 0, planCount == 0 {
            return countText(permissionCount, singular: "permission request pending", plural: "permission requests pending")
        }
        return countText(totalCount, singular: "request pending", plural: "requests pending")
    }

    private var actionText: String {
        permissionCount == 0 ? "Answer" : "Review"
    }

    var body: some View {
        if !isEmpty {
            content
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var content: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: bannerIcon)
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)

                Text(bannerText)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer(minLength: 8)

                Text(actionText)
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.accent, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .fill(ClaudeTheme.accentSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .strokeBorder(ClaudeTheme.accent.opacity(isHovered ? 0.55 : 0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private func open() {
        // Prefer surfacing pending plans first — they typically block forward
        // progress on the conversation while questions/permissions are usually
        // about a single in-flight tool call.
        if let plan = pendingPlans.first {
            windowState.presentedPlanToolCallId = plan.toolCallId
            return
        }
        windowState.presentedPermissionId = pendingRequests.first?.id
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
