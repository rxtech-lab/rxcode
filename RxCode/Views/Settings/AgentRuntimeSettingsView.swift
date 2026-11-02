import RxCodeCore
import SwiftUI

struct AgentRuntimeSettingsView: View {
    @Environment(AppState.self) private var appState
    let runtime: AgentRuntimeInstaller.Runtime
    let catalog: Bool
    @State private var installingRuntime: AgentRuntimeInstaller.Runtime?
    @State private var signingInRuntime: AgentRuntimeInstaller.Runtime?
    @State private var installSheetRuntime: AgentRuntimeInstaller.Runtime?
    @State private var runtimeMessage: String?
    @State private var pendingRemoval: AgentRuntimeInstaller.Runtime?
    @State private var latestVersion: String?
    @State private var updateCheckFailed = false
    @State private var isCheckingForUpdates = false
    @State private var initialInstallVersion: String?

    private var currentVersion: String? {
        runtime == .claude ? appState.claudeVersion : appState.codexVersion
    }

    private var availableUpdate: String? {
        guard let latestVersion, AgentRuntimeVersion.isUpdate(latestVersion, for: currentVersion) else { return nil }
        return latestVersion
    }

    var body: some View {
        agentRuntimeRow(
            runtime: runtime,
            title: runtime.displayName,
            installed: runtime == .claude ? appState.claudeInstalled : appState.codexInstalled,
            signedIn: runtime == .claude ? appState.claudeSignedIn : appState.codexSignedIn,
            version: runtime == .claude ? appState.claudeVersion : appState.codexVersion,
            path: runtime == .claude ? appState.claudeBinaryPath : appState.codexBinaryPath,
        )
            .sheet(item: $installSheetRuntime) { runtime in
                AgentRuntimeInstallSheet(
                    runtime: runtime,
                    installedVersion: AgentRuntimeVersion.parse(currentVersion),
                    initialVersion: initialInstallVersion,
                    onInstalled: { await appState.refreshAgentInstallations() },
                )
            }
            .task(id: currentVersion) {
                await checkForUpdates()
            }
            .alert("Remove managed runtime?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } },
            ), presenting: pendingRemoval) { runtime in
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
                Button("Remove", role: .destructive) {
                    pendingRemoval = nil
                    remove(runtime)
                }
            } message: { _ in
                Text("RxCode's managed copy will be removed. Separately installed copies are managed outside RxCode.")
            }
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
                }
            }
    }

    private func managementMenu(_ runtime: AgentRuntimeInstaller.Runtime) -> some View {
        let signedIn = runtime == .claude ? appState.claudeSignedIn : appState.codexSignedIn
        let path = runtime == .claude ? appState.claudeBinaryPath : appState.codexBinaryPath
        return Menu("Manage…") {
            if let availableUpdate {
                Button("Update to \(availableUpdate)…") {
                    initialInstallVersion = availableUpdate
                    installSheetRuntime = runtime
                }
            }
            Button("Install Version…") {
                initialInstallVersion = nil
                installSheetRuntime = runtime
            }
            Button(isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates") {
                Task { await checkForUpdates(forceRefresh: true) }
            }
            .disabled(isCheckingForUpdates)
            Divider()
            Button(signedIn ? "Re-sign In" : "Sign In") { signIn(runtime) }
            if signedIn { Button("Sign Out") { signOut(runtime) } }
            if path == AgentRuntimeInstaller.executablePath(for: runtime) {
                Divider()
                Button("Remove…", role: .destructive) { pendingRemoval = runtime }
            }
        }
        .fixedSize()
        .controlSize(.small)
        .disabled(signingInRuntime != nil || installingRuntime != nil)
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
                if installed, let availableUpdate {
                    Text("Update available: \(availableUpdate)")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                } else if installed, updateCheckFailed {
                    Text("Could not check for updates. Retry from Manage.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if signingInRuntime == runtime || installingRuntime == runtime {
                ProgressView().controlSize(.small)
            }
            if catalog {
                Button("Install…") {
                    initialInstallVersion = nil
                    installSheetRuntime = runtime
                }
                    .controlSize(.small)
                    .disabled(signingInRuntime != nil || installingRuntime != nil)
            } else {
                managementMenu(runtime)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1),
        )
    }

    private func checkForUpdates(forceRefresh: Bool = false) async {
        guard !catalog, currentVersion != nil else { return }
        isCheckingForUpdates = true
        updateCheckFailed = false
        defer { isCheckingForUpdates = false }
        do {
            let version = try await AgentVersionCatalog.shared.latestVersion(for: runtime, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            latestVersion = version
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            latestVersion = nil
            updateCheckFailed = true
        }
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
