import SwiftUI
import RxCodeCore

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    var onCompletion: (() -> Void)? = nil
    @State private var isCheckingCLI = false
    @State private var claudeInstalled = false
    @State private var claudeVersion: String?
    @State private var claudeError: String?
    @State private var codexInstalled = false
    @State private var codexVersion: String?
    @State private var codexError: String?

    private var canContinue: Bool { claudeInstalled || codexInstalled }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            cliCheckStep
                .frame(maxWidth: 460)

            Spacer()

            navigationButtons
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 40)
        .frame(width: 600, height: 560)
        .background(ClaudeTheme.background)
        .task {
            await checkCLI()
        }
    }

    // MARK: - CLI Check

    private var cliCheckStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: ClaudeTheme.size(48)))
                .foregroundStyle(ClaudeTheme.accent)

            Text("Claude CLI Installation Check")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(ClaudeTheme.textPrimary)

            if isCheckingCLI {
                ProgressView("Checking...")
            }

            VStack(spacing: 10) {
                cliStatusRow(
                    title: "Claude Code",
                    installed: claudeInstalled,
                    version: claudeVersion,
                    error: claudeError,
                    installCommand: "npm install -g @anthropic-ai/claude-code"
                )
                cliStatusRow(
                    title: "Codex",
                    installed: codexInstalled,
                    version: codexVersion,
                    error: codexError,
                    installCommand: "npm install -g @openai/codex"
                )
            }

            Button("Check Again") {
                Task { await checkCLI() }
            }
            .buttonStyle(ClaudeSecondaryButtonStyle())
            .padding(.top, 4)
        }
    }

    private func cliStatusRow(
        title: String,
        installed: Bool,
        version: String?,
        error: String?,
        installCommand: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    installed ? "\(title) installed\(version.map { " — \($0)" } ?? "")" : "\(title) not found",
                    systemImage: installed ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                .font(.body)
                Spacer()
            }

            if !installed {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                HStack {
                    Text(installCommand)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(ClaudeTheme.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
        }
        .padding(12)
        .background(ClaudeTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            Spacer()
            Button("Get Started") {
                appState.skipGitHubLogin()
                onCompletion?()
            }
            .buttonStyle(ClaudeAccentButtonStyle())
            .disabled(!canContinue)
        }
    }

    // MARK: - Helpers

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

#Preview {
    OnboardingView()
        .environment(AppState())
}
