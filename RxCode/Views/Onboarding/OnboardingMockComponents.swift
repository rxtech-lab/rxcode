import RxCodeCore
import SwiftUI

// MARK: - Workspace / approval previews

struct WorkspacePreview: View {
    var body: some View {
        OnboardingMockWindow(title: "RxCode") {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    PreviewSidebarRow(icon: "folder", title: LocalizedStringKey("Projects"), isActive: true)
                    PreviewSidebarRow(icon: "clock", title: LocalizedStringKey("Threads"), isActive: false)
                    PreviewSidebarRow(icon: "doc.text", title: LocalizedStringKey("Briefing"), isActive: false)
                    Spacer()
                }
                .frame(width: 148)
                .padding(14)
                .background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 12) {
                    PreviewBubble(title: LocalizedStringKey("Refactor onboarding into slides"), isUser: true)
                    PreviewToolRow(icon: "terminal", title: LocalizedStringKey("Running swift build"), accent: ClaudeTheme.statusRunning)
                    PreviewBubble(title: LocalizedStringKey("I found the existing onboarding view and will keep the CLI check as setup."), isUser: false)
                    Spacer()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 620)
    }
}

struct ApprovalPreview: View {
    var body: some View {
        OnboardingMockWindow(title: LocalizedStringKey("Permission Request")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Review Command")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("The agent wants to run a command in this project.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }

                Text(verbatim: "xcodebuild -project RxCode.xcodeproj -scheme RxCode build")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    PreviewActionButton(title: LocalizedStringKey("Deny"), fill: Color.white.opacity(0.12))
                    PreviewActionButton(title: LocalizedStringKey("Allow"), fill: ClaudeTheme.accent)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: 540)
    }
}

// MARK: - Shared layout primitives

struct OnboardingMockWindow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = LocalizedStringKey(title)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red.opacity(0.82)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.82)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.82)).frame(width: 10, height: 10)
                Spacer()
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.black.opacity(0.32))

            content
                .frame(height: 268)
                .background(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x171A23),
                            Color(hex: 0x202536),
                            Color(hex: 0x11131A)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 14)
    }
}

struct PreviewSidebarRow: View {
    let icon: String
    let title: LocalizedStringKey
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .foregroundStyle(isActive ? .white : .white.opacity(0.58))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isActive ? ClaudeTheme.accent.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PreviewBubble: View {
    let title: LocalizedStringKey
    let isUser: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: isUser ? 250 : 340, alignment: .leading)
            .background(isUser ? ClaudeTheme.accent.opacity(0.72) : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

struct PreviewToolRow: View {
    let icon: String
    let title: LocalizedStringKey
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PreviewActionButton: View {
    let title: LocalizedStringKey
    let fill: Color

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
