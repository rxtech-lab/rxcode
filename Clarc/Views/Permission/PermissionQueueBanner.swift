import SwiftUI
import ClarcCore

/// Compact pill displayed directly above the chat input bar whenever the CLI
/// has pending permission requests. Tapping it surfaces the full
/// `PermissionModal` for the first queued request — streaming/typing is never
/// interrupted until the user explicitly opens it.
struct PermissionQueueBanner: View {
    @Environment(WindowState.self) private var windowState
    @State private var isHovered: Bool = false

    var body: some View {
        if !windowState.pendingPermissions.isEmpty {
            content
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var content: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)

                Text("\(windowState.pendingPermissions.count) question(s) pending")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer(minLength: 8)

                Text("Answer")
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
        windowState.presentedPermissionId = windowState.pendingPermissions.first?.id
    }
}
