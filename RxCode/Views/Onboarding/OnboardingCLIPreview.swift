import RxCodeCore
import SwiftUI

struct CLISetupPreview: View {
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
                Text(claudeInstalled || codexInstalled ? LocalizedStringKey("Ready to start.") : LocalizedStringKey("Install one CLI, then check again."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Button {
                    onCheckAgain()
                } label: {
                    Text("Check Again")
                }
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

struct CLIStatusRow: View {
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
                Text(verbatim: installed
                     ? "\(title) \(String(localized: "installed"))\(version.map { " - \($0)" } ?? "")"
                     : "\(title) \(String(localized: "not found"))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }

            if !installed {
                if let error {
                    Text(verbatim: error)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(verbatim: installCommand)
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
                    .help(LocalizedStringKey("Copy install command"))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
