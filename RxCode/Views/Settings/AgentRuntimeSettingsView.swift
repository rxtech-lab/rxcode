import RxCodeCore
import SwiftUI

struct AgentRuntimeSettingsView: View {
    @Environment(AppState.self) private var appState
    let catalog: Bool
    @State private var installingRuntime: AgentRuntimeInstaller.Runtime?
    @State private var signingInRuntime: AgentRuntimeInstaller.Runtime?
    @State private var installSheetRuntime: AgentRuntimeInstaller.Runtime?
    @State private var runtimeMessage: String?
    @State private var managingRuntime: AgentRuntimeInstaller.Runtime?
    @State private var pendingRemoval: AgentRuntimeInstaller.Runtime?

    var body: some View {
        agentRuntimeSection
            .sheet(item: Binding(
                get: { catalog ? installSheetRuntime : nil },
                set: { installSheetRuntime = $0 },
            )) { runtime in
                AgentRuntimeInstallSheet(
                    runtime: runtime,
                    installedVersion: installedVersion(in: runtime == .claude ? appState.claudeVersion : appState.codexVersion),
                    onInstalled: { await appState.refreshAgentInstallations() },
                )
            }
            .sheet(item: $managingRuntime) { runtime in
                managementSheet(runtime)
                    .sheet(item: $installSheetRuntime) { selection in
                        AgentRuntimeInstallSheet(
                            runtime: selection,
                            installedVersion: installedVersion(in: selection == .claude ? appState.claudeVersion : appState.codexVersion),
                            onInstalled: { await appState.refreshAgentInstallations() },
                        )
                    }
                    .alert("Remove managed runtime?", isPresented: Binding(
                        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } },
                    )) {
                        Button("Cancel", role: .cancel) { pendingRemoval = nil }
                        Button("Remove", role: .destructive) {
                            pendingRemoval = nil
                            remove(runtime)
                        }
                    } message: {
                        Text("RxCode's managed copy will be removed. Separately installed copies are managed outside RxCode.")
                    }
            }
    }

    private func managementSheet(_ runtime: AgentRuntimeInstaller.Runtime) -> some View {
        let signedIn = runtime == .claude ? appState.claudeSignedIn : appState.codexSignedIn
        let path = runtime == .claude ? appState.claudeBinaryPath : appState.codexBinaryPath
        return VStack(alignment: .leading, spacing: 16) {
            Text("Manage \(runtime.displayName)").font(.headline)
            Text(path ?? "No executable detected").font(.caption).textSelection(.enabled)
            Form {
                Button("Install Version…") { installSheetRuntime = runtime }
                Button(signedIn ? "Re-sign In" : "Sign In") { signIn(runtime) }
                if signedIn { Button("Sign Out") { signOut(runtime) } }
                if path == AgentRuntimeInstaller.executablePath(for: runtime) {
                    Button("Remove…", role: .destructive) { pendingRemoval = runtime }
                }
            }
            .disabled(signingInRuntime != nil || installingRuntime != nil)
            HStack {
                Spacer()
                Button("Done") { managingRuntime = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(signingInRuntime != nil || installingRuntime != nil)
            }
        }
        .padding(24)
        .frame(width: 460, height: 330)
        .interactiveDismissDisabled(signingInRuntime != nil || installingRuntime != nil)
        .overlay(alignment: .bottom) {
            if signingInRuntime != nil || installingRuntime != nil || runtimeMessage != nil {
                HStack {
                    if signingInRuntime != nil || installingRuntime != nil { ProgressView().controlSize(.small) }
                    Text(runtimeMessage ?? "Working…")
                    if runtimeMessage != nil { Button("Dismiss") { runtimeMessage = nil } }
                }
                .font(.callout)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 60)
            }
        }
    }

    // MARK: - Agent Runtime Section

    private var agentRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                if catalog || appState.claudeInstalled { agentRuntimeRow(
                    runtime: .claude,
                    title: "Claude Code",
                    installed: appState.claudeInstalled,
                    signedIn: appState.claudeSignedIn,
                    version: appState.claudeVersion,
                    path: appState.claudeBinaryPath,
                ) }
                if catalog || appState.codexInstalled { agentRuntimeRow(
                    runtime: .codex,
                    title: "Codex",
                    installed: appState.codexInstalled,
                    signedIn: appState.codexSignedIn,
                    version: appState.codexVersion,
                    path: appState.codexBinaryPath,
                ) }
            }
            if catalog {
                Text("Claude Code and Codex downloads use npm and are stored in RxCode's application support folder.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func agentRuntimeRow(
        runtime: AgentRuntimeInstaller.Runtime,
        title: String,
        installed: Bool,
        signedIn: Bool,
        version: String?,
        path: String?,
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                .font(.system(size: ClaudeTheme.size(14)))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text(installed ? "Installed" : "Not found")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                    if let version, !version.isEmpty {
                        Text(version)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                    }
                    if installed, signedIn {
                        Text("Signed In")
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                }

                Text(path ?? "No executable detected")
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(path == nil ? .secondary : ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            if signingInRuntime == runtime || installingRuntime == runtime {
                ProgressView().controlSize(.small)
            }
            Button(catalog ? "Install…" : "Manage…") {
                if catalog { installSheetRuntime = runtime } else { managingRuntime = runtime }
            }
            .controlSize(.small)
            .disabled(installingRuntime != nil)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1),
        )
    }

    private func installedVersion(in output: String?) -> String? {
        guard let output,
              let range = output.range(
                  of: #"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"#,
                  options: .regularExpression,
              )
        else { return nil }
        return String(output[range])
    }

    private func remove(_ runtime: AgentRuntimeInstaller.Runtime) {
        installingRuntime = runtime
        runtimeMessage = nil
        Task {
            defer { installingRuntime = nil }
            do {
                try await AgentRuntimeInstaller.shared.uninstall(runtime)
                await appState.refreshAgentInstallations()
                runtimeMessage = "RxCode's managed copy was removed."
            } catch {
                runtimeMessage = error.localizedDescription
            }
        }
    }

    private func signIn(_ runtime: AgentRuntimeInstaller.Runtime) {
        signingInRuntime = runtime
        runtimeMessage = nil
        Task {
            defer { signingInRuntime = nil }
            do {
                switch runtime {
                case .codex:
                    try await appState.codex.signIn()
                case .claude:
                    do {
                        try await appState.claude.signIn()
                    } catch {
                        try ClaudeCodeServer.openLoginInTerminal(binary: appState.claudeBinaryPath ?? "claude")
                        runtimeMessage = "Complete Claude Code sign-in in Terminal."
                        return
                    }
                }
                runtimeMessage = "Sign-in completed."
                await appState.refreshAgentSignInStatus()
            } catch {
                runtimeMessage = error.localizedDescription
            }
        }
    }

    private func signOut(_ runtime: AgentRuntimeInstaller.Runtime) {
        signingInRuntime = runtime
        runtimeMessage = nil
        Task {
            defer { signingInRuntime = nil }
            do {
                switch runtime {
                case .codex:
                    try await appState.codex.signOut()
                case .claude:
                    try await appState.claude.signOut()
                }
                await appState.refreshAgentSignInStatus()
                let stillSignedIn = runtime == .codex ? appState.codexSignedIn : appState.claudeSignedIn
                runtimeMessage = stillSignedIn
                    ? "Stored sign-in cleared, but this runtime still has credentials from its environment."
                    : "Signed out."
            } catch {
                runtimeMessage = error.localizedDescription
            }
        }
    }
}
