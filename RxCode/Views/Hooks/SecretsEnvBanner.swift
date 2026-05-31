import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Banner shown on the new-project screen when a project has a local `.env*`
/// file that isn't backed up to autopilot (or the repo has no secrets set up).
/// Built by `AutopilotHook` and rendered via `HookBannerHost`. The
/// "Set up" button opens the secrets deep link, which `MainWindowRoot` routes
/// to the secret-setup form.
struct SecretsEnvBanner: View {
    let repo: String
    let projectPath: String?
    /// The missing file (e.g. `.env`), or nil when the repo has no secrets at all.
    let missingFile: String?
    /// Called when the user taps the close button. The hook persists the
    /// dismissal so the banner won't reappear.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var message: String {
        if let missingFile {
            return String(format: String(localized: "%@ isn't backed up to Autopilot"), missingFile)
        }
        return String(localized: "Back up this project's secrets to Autopilot")
    }

    var body: some View {
        HStack(spacing: 8) {
            // Main call-to-action: the whole row (minus the close button) opens
            // the secrets setup deep link.
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
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

            // Dismiss: persists so the banner won't return for this project.
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
        guard let url = SecretsDeepLink.addURL(repo: repo, path: projectPath, file: missingFile) else { return }
        openURL(url)
    }
}
