import SwiftUI
import RxCodeCore

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    var onCompletion: (() -> Void)? = nil

    @State private var selectedIndex = 0
    @State private var isCheckingCLI = false
    @State private var claudeInstalled = false
    @State private var claudeVersion: String?
    @State private var claudeError: String?
    @State private var codexInstalled = false
    @State private var codexVersion: String?
    @State private var codexError: String?

    private let slides = OnboardingSlide.all

    private var isFirstSlide: Bool {
        selectedIndex == 0
    }

    private var isLastSlide: Bool {
        selectedIndex == slides.count - 1
    }

    private var canContinue: Bool {
        !isLastSlide || claudeInstalled || codexInstalled
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - 72, 820)

            ZStack {
                onboardingBackdrop

                slideCard
                    .frame(width: contentWidth, height: min(proxy.size.height - 68, 600))
                    .padding(.vertical, 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 640, idealHeight: 700)
        .background(ClaudeTheme.background)
        .task {
            await checkCLI()
        }
    }

    private var onboardingBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    ClaudeTheme.background,
                    ClaudeTheme.surfaceSecondary.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                ClaudeTheme.accent.opacity(0.22),
                                ClaudeTheme.surfacePrimary.opacity(0.08),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 260)
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    private var slideCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ClaudeTheme.surfaceElevated,
                            ClaudeTheme.surfacePrimary,
                            ClaudeTheme.background.opacity(0.96)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 28, y: 18)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)

            ZStack {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    slideContent(slide)
                        .opacity(selectedIndex == index ? 1 : 0)
                        .scaleEffect(selectedIndex == index ? 1 : 0.96)
                        .offset(x: CGFloat(index - selectedIndex) * 72)
                        .allowsHitTesting(selectedIndex == index)
                }
            }
            .animation(.snappy(duration: 0.46), value: selectedIndex)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func slideContent(_ slide: OnboardingSlide) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                slideVisual(slide.visual)
                    .padding(.horizontal, 42)
                    .padding(.top, 36)
                    .padding(.bottom, 22)

                HStack {
                    circularNavigationButton(systemImage: "chevron.left") {
                        goBack()
                    }
                    .opacity(isFirstSlide ? 0.26 : 1)
                    .disabled(isFirstSlide)

                    Spacer()

                    circularNavigationButton(systemImage: isLastSlide ? "checkmark" : "chevron.right") {
                        advance()
                    }
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.38)
                }
                .padding(20)
            }

            pageIndicator
                .padding(.bottom, 24)

            VStack(spacing: 9) {
                Text(slide.title)
                    .font(.system(size: ClaudeTheme.size(28), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(slide.subtitle)
                    .font(.system(size: ClaudeTheme.size(15)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }
            .padding(.horizontal, 48)

            Spacer(minLength: 18)

            Button {
                advance()
            } label: {
                Text(isLastSlide ? "Get Started" : "Continue")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .frame(width: 230, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(canContinue ? ClaudeTheme.accent : ClaudeTheme.textTertiary, in: Capsule())
            .shadow(color: ClaudeTheme.accent.opacity(canContinue ? 0.24 : 0), radius: 12, y: 6)
            .disabled(!canContinue)
            .padding(.bottom, 34)
        }
    }

    @ViewBuilder
    private func slideVisual(_ visual: OnboardingSlide.Visual) -> some View {
        switch visual {
        case .workspace:
            WorkspacePreview()
        case .approvals:
            ApprovalPreview()
        case .sync:
            SyncPreview()
        case .cliSetup:
            CLISetupPreview(
                isCheckingCLI: isCheckingCLI,
                claudeInstalled: claudeInstalled,
                claudeVersion: claudeVersion,
                claudeError: claudeError,
                codexInstalled: codexInstalled,
                codexVersion: codexVersion,
                codexError: codexError,
                onCheckAgain: { Task { await checkCLI() } }
            )
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(slides.indices, id: \.self) { index in
                Capsule()
                    .fill(index == selectedIndex ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary.opacity(0.36))
                    .frame(width: index == selectedIndex ? 24 : 8, height: 8)
                    .animation(.snappy(duration: 0.28), value: selectedIndex)
            }
        }
        .accessibilityHidden(true)
    }

    private func circularNavigationButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(17), weight: .semibold))
                .frame(width: 42, height: 42)
                .foregroundStyle(.white)
                .background(.white.opacity(0.18), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(systemImage == "chevron.left" ? "Back" : "Continue")
    }

    private func goBack() {
        guard selectedIndex > 0 else { return }
        withAnimation(.snappy(duration: 0.42)) {
            selectedIndex -= 1
        }
    }

    private func advance() {
        guard canContinue else { return }

        if isLastSlide {
            completeOnboarding()
        } else {
            withAnimation(.snappy(duration: 0.42)) {
                selectedIndex += 1
            }
        }
    }

    private func completeOnboarding() {
        appState.onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onCompletion?()
    }

    private func checkCLI() async {
        isCheckingCLI = true
        claudeError = nil
        codexError = nil

        do {
            let version = try await appState.claude.checkVersion()
            claudeVersion = version
            claudeInstalled = true
            appState.claudeInstalled = true
            appState.claudeVersion = version
            appState.claudeBinaryPath = await appState.claude.findClaudeBinary()
        } catch {
            claudeInstalled = false
            claudeVersion = nil
            claudeError = error.localizedDescription

            let binary = await appState.claude.findClaudeBinary()
            appState.claudeBinaryPath = binary
            if let binary {
                claudeError = "Binary found: \(binary), but version check failed"
                claudeInstalled = true
                appState.claudeInstalled = true
                appState.claudeVersion = nil
            } else {
                appState.claudeInstalled = false
                appState.claudeVersion = nil
            }
        }

        do {
            let version = try await appState.codex.checkVersion()
            codexVersion = version
            codexInstalled = true
            appState.codexInstalled = true
            appState.codexVersion = version
            appState.codexBinaryPath = await appState.codex.findCodexBinary()
        } catch {
            codexInstalled = false
            codexVersion = nil
            codexError = error.localizedDescription

            let binary = await appState.codex.findCodexBinary()
            appState.codexBinaryPath = binary
            if let binary {
                codexError = "Binary found: \(binary), but version check failed"
                codexInstalled = true
                appState.codexInstalled = true
                appState.codexVersion = nil
            } else {
                appState.codexInstalled = false
                appState.codexVersion = nil
            }
        }

        isCheckingCLI = false
    }
}

private struct OnboardingSlide: Identifiable {
    enum Visual {
        case workspace
        case approvals
        case sync
        case cliSetup
    }

    let id: String
    let title: String
    let subtitle: String
    let visual: Visual

    static let all: [OnboardingSlide] = [
        OnboardingSlide(
            id: "workspace",
            title: "Work with coding agents in one native app",
            subtitle: "Open projects, switch threads, and keep agent conversations close to the files they change.",
            visual: .workspace
        ),
        OnboardingSlide(
            id: "approvals",
            title: "Approve risky actions with context",
            subtitle: "Review commands, diffs, and permission requests before an agent changes your workspace.",
            visual: .approvals
        ),
        OnboardingSlide(
            id: "sync",
            title: "Stay connected across devices",
            subtitle: "Pair mobile devices, monitor running work, and jump back into active threads when you return.",
            visual: .sync
        ),
        OnboardingSlide(
            id: "cli",
            title: "Connect at least one agent CLI",
            subtitle: "RxCode runs Claude Code or Codex locally. Install one of them to start your first project.",
            visual: .cliSetup
        )
    ]
}

private struct WorkspacePreview: View {
    var body: some View {
        OnboardingMockWindow(title: "RxCode") {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    PreviewSidebarRow(icon: "folder", title: "Projects", isActive: true)
                    PreviewSidebarRow(icon: "clock", title: "Threads", isActive: false)
                    PreviewSidebarRow(icon: "doc.text", title: "Briefing", isActive: false)
                    Spacer()
                }
                .frame(width: 148)
                .padding(14)
                .background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 12) {
                    PreviewBubble(title: "Refactor onboarding into slides", isUser: true)
                    PreviewToolRow(icon: "terminal", title: "Running swift build", accent: ClaudeTheme.statusRunning)
                    PreviewBubble(title: "I found the existing onboarding view and will keep the CLI check as setup.", isUser: false)
                    Spacer()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 620)
    }
}

private struct ApprovalPreview: View {
    var body: some View {
        OnboardingMockWindow(title: "Permission Request") {
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

                Text("xcodebuild -project RxCode.xcodeproj -scheme RxCode build")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    PreviewActionButton(title: "Deny", fill: Color.white.opacity(0.12))
                    PreviewActionButton(title: "Allow", fill: ClaudeTheme.accent)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: 540)
    }
}

private struct SyncPreview: View {
    var body: some View {
        HStack(spacing: 20) {
            OnboardingDeviceFrame(name: "Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    PreviewToolRow(icon: "sparkles", title: "Agent is editing", accent: ClaudeTheme.accent)
                    PreviewBubble(title: "3 files changed", isUser: false)
                    PreviewProgressLine(width: 160)
                    PreviewProgressLine(width: 118)
                }
                .padding(18)
            }

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)

            OnboardingDeviceFrame(name: "iPhone", compact: true) {
                VStack(alignment: .leading, spacing: 10) {
                    PreviewToolRow(icon: "bolt.fill", title: "Live", accent: ClaudeTheme.statusSuccess)
                    PreviewProgressLine(width: 86)
                    PreviewProgressLine(width: 112)
                    PreviewProgressLine(width: 72)
                }
                .padding(15)
            }
        }
        .frame(maxWidth: 620, minHeight: 306)
    }
}

private struct CLISetupPreview: View {
    let isCheckingCLI: Bool
    let claudeInstalled: Bool
    let claudeVersion: String?
    let claudeError: String?
    let codexInstalled: Bool
    let codexVersion: String?
    let codexError: String?
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Agent CLI Setup")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if isCheckingCLI {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(spacing: 10) {
                CLIStatusRow(
                    title: "Claude Code",
                    installed: claudeInstalled,
                    version: claudeVersion,
                    error: claudeError,
                    installCommand: "npm install -g @anthropic-ai/claude-code"
                )
                CLIStatusRow(
                    title: "Codex",
                    installed: codexInstalled,
                    version: codexVersion,
                    error: codexError,
                    installCommand: "npm install -g @openai/codex"
                )
            }

            HStack {
                Text(claudeInstalled || codexInstalled ? "Ready to start." : "Install one CLI, then check again.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                    .disabled(isCheckingCLI)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct CLIStatusRow: View {
    let title: String
    let installed: Bool
    let version: String?
    let error: String?
    let installCommand: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                Text(installed ? "\(title) installed\(version.map { " - \($0)" } ?? "")" : "\(title) not found")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }

            if !installed {
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(installCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help("Copy install command")
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct OnboardingMockWindow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

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

private struct OnboardingDeviceFrame<Content: View>: View {
    let name: String
    var compact = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(height: 28)
            content
                .frame(width: compact ? 152 : 240, height: compact ? 214 : 190)
                .background(Color.black.opacity(0.28))
        }
        .background(
            RoundedRectangle(cornerRadius: compact ? 26 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x1C2230), Color(hex: 0x11141B)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 26 : 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
    }
}

private struct PreviewSidebarRow: View {
    let icon: String
    let title: String
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

private struct PreviewBubble: View {
    let title: String
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

private struct PreviewToolRow: View {
    let icon: String
    let title: String
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

private struct PreviewActionButton: View {
    let title: String
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

private struct PreviewProgressLine: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white.opacity(0.16))
            .frame(width: width, height: 8)
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}
