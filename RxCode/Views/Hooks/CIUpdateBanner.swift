import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Banner shown on the new-project screen when a project has local
/// `.github/workflows/*.yml|yaml` files but its repo isn't yet watched for CI
/// auto-updates. Built by `CIUpdateHook` and rendered via `HookBannerHost`. The
/// "Set up" button opens the CI deep link, which `MainView` routes to the CI
/// auto-update manage sheet pre-targeted at this repo.
struct CIUpdateBanner: View {
    let repo: String
    let projectPath: String?
    /// Number of local workflow files detected, for the message copy.
    let workflowCount: Int
    /// Called when the user taps the close button. The hook persists the
    /// dismissal so the banner won't reappear.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var message: String {
        String(localized: "Keep this repo's GitHub Actions up to date automatically")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)

                    Text(message)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Text("Set up")
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(ClaudeTheme.accent, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .pointerCursorOnHover()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                    .foregroundStyle(ClaudeTheme.textSecondary.opacity(isCloseHovered ? 1 : 0.6))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(ClaudeTheme.textSecondary.opacity(isCloseHovered ? 0.12 : 0))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
            .pointerCursorOnHover()
            .help("Dismiss")
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
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isCloseHovered)
    }

    private func open() {
        guard let url = CIUpdateDeepLink.addURL(repo: repo, path: projectPath) else { return }
        openURL(url)
    }
}
