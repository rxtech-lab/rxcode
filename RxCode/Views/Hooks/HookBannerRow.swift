import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// A single compact hook-banner row: a leading accent icon, the message, an
/// optional "Set up" action pill, and a trailing dismiss button. Only the action
/// pill is tappable — clicking elsewhere on the banner does nothing.
///
/// Rows render **no** outer card chrome of their own — `HookBannerHost` wraps
/// one or more rows in a single shared container so stacked banners read as one
/// grouped card instead of a column of separate boxes.
struct HookBannerRow: View {
    let icon: String
    let message: String
    var actionTitle: String = .init(localized: "Set up")
    let onTap: () -> Void
    let onDismiss: () -> Void
    /// When true the action pill is disabled + dimmed — used while you're already
    /// inside the setup chat this banner would otherwise create a duplicate of.
    var isActionDisabled: Bool = false
    /// Tooltip shown on the disabled action pill, explaining why it's inert.
    var disabledHelp: String = .init(localized: "You're already in this setup chat")

    @State private var isActionHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .foregroundStyle(Color.hookBannerAccent)
                    .frame(width: ClaudeTheme.size(18))

                Text(message)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(action: onTap) {
                    Text(actionTitle)
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(.white.opacity(isActionDisabled ? 0.7 : 1))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Color.hookBannerAccent.opacity(
                                isActionDisabled ? 0.35 : (isActionHovered ? 0.8 : 1)
                            ),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
                .onHover { isActionHovered = $0 && !isActionDisabled }
                .pointerCursorOnHover()
                .help(isActionDisabled ? disabledHelp : "")
            }

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
        .padding(.vertical, 9)
        .background(Color.hookBannerAccent.opacity(0.2))
        .animation(.easeInOut(duration: 0.12), value: isActionHovered)
        .animation(.easeInOut(duration: 0.12), value: isCloseHovered)
    }
}

#Preview {
    VStack(spacing: 0) {
        HookBannerRow(
            icon: "bell.badge",
            message: "Enable notifications to stay updated",
            onTap: {},
            onDismiss: {}
        )

        Divider()

        HookBannerRow(
            icon: "key.fill",
            message: "Add your API key to unlock all features",
            actionTitle: "Configure",
            onTap: {},
            onDismiss: {}
        )

        Divider()

        HookBannerRow(
            icon: "arrow.triangle.2.circlepath",
            message: "A new version is available with important bug fixes and performance improvements",
            actionTitle: "Update",
            onTap: {},
            onDismiss: {}
        )
    }
    .frame(width: 400)
    .background(Color(.windowBackgroundColor))
}
