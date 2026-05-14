import SwiftUI
import RxCodeCore

/// Compact pill displayed directly above the chat input bar whenever the CLI
/// has pending permission requests. Tapping it surfaces the full
/// `PermissionModal` for the first queued request — streaming/typing is never
/// interrupted until the user explicitly opens it.
struct PermissionQueueBanner: View {
    @Environment(WindowState.self) private var windowState
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

    private var bannerIcon: String {
        permissionCount == 0 ? "questionmark.circle.fill" : "exclamationmark.shield.fill"
    }

    private var bannerText: String {
        if questionCount > 0, permissionCount == 0 {
            return countText(questionCount, singular: "question pending", plural: "questions pending")
        }

        if permissionCount > 0, questionCount == 0 {
            return countText(permissionCount, singular: "permission request pending", plural: "permission requests pending")
        }

        return countText(pendingRequests.count, singular: "request pending", plural: "requests pending")
    }

    private var actionText: String {
        permissionCount == 0 ? "Answer" : "Review"
    }

    var body: some View {
        if !pendingRequests.isEmpty {
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
        windowState.presentedPermissionId = pendingRequests.first?.id
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
