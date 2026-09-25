import RxCodeCore
import SwiftUI

extension AgentRuntimeInstaller.Runtime: Identifiable {
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

// MARK: - Agent Runtime Install Sheet

/// Lets the user pick a published version and shows download progress while
/// npm installs it into RxCode's managed prefix.
struct AgentRuntimeInstallSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runtime: AgentRuntimeInstaller.Runtime
    let installedVersion: String?
    let onInstalled: () async -> Void

    @State private var availableVersions: [String] = []
    @State private var isLoadingVersions = false
    @State private var versionError: String?

    @State private var selectedVersion = "latest"
    @State private var progress: AgentRuntimeInstaller.Progress?
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var didFinish = false
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            versionPicker
            if isInstalling || didFinish || progress != nil {
                progressSection
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(isInstalling)
        .task { await loadVersions() }
        .onDisappear { installTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Install \(runtime.displayName)")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
            Text(installedVersion.map { "Currently installed: \($0)" } ?? "Not installed")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var versionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Version", selection: $selectedVersion) {
                    Text("Latest").tag("latest")
                    ForEach(availableVersions, id: \.self) { version in
                        Text(version).tag(version)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isInstalling)
                .accessibilityLabel("\(runtime.displayName) version")
                if isLoadingVersions {
                    ProgressView().controlSize(.small)
                }
            }
            if let versionError {
                HStack(spacing: 6) {
                    Text(versionError)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await loadVersions() } }
                        .buttonStyle(.link)
                }
                .font(.system(size: ClaudeTheme.size(11)))
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if didFinish {
                ProgressView(value: 1)
            } else if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(statusText)
                Spacer()
                if let bytesText {
                    Text(bytesText)
                        .monospacedDigit()
                }
            }
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if didFinish {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") {
                    installTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)
                Button {
                    install()
                } label: {
                    Text(isInstalling ? "Installing…" : "Install")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling)
            }
        }
    }

    private var targetVersionLabel: String {
        progress?.resolvedVersion ?? (selectedVersion == "latest" ? "latest" : selectedVersion)
    }

    private var statusText: String {
        if didFinish { return "Installed \(runtime.displayName) \(targetVersionLabel)." }
        switch progress?.phase {
        case .none, .resolving: return "Resolving \(targetVersionLabel)…"
        case .downloading: return "Downloading \(targetVersionLabel)…"
        case .finalizing: return "Finishing installation…"
        }
    }

    private var bytesText: String? {
        guard let progress, progress.downloadedBytes > 0 else { return nil }
        let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
        guard let expected = progress.expectedBytes, expected > 0 else { return downloaded }
        let total = ByteCountFormatter.string(fromByteCount: max(expected, progress.downloadedBytes), countStyle: .file)
        return "\(downloaded) of \(total)"
    }

    private func loadVersions() async {
        isLoadingVersions = true
        versionError = nil
        defer { isLoadingVersions = false }
        do {
            availableVersions = try await AgentVersionCatalog.shared.versions(for: runtime)
            if selectedVersion == "latest", let installedVersion, availableVersions.contains(installedVersion) {
                selectedVersion = installedVersion
            }
        } catch is CancellationError {
            return
        } catch {
            versionError = "Could not load published versions: \(error.localizedDescription)"
        }
    }

    private func install() {
        isInstalling = true
        errorMessage = nil
        progress = AgentRuntimeInstaller.Progress(phase: .resolving)
        let version = selectedVersion
        installTask = Task {
            defer { isInstalling = false }
            do {
                try await AgentRuntimeInstaller.shared.install(runtime, version: version) { update in
                    Task { @MainActor in
                        // Monitor ticks can land after the finalizing update.
                        if progress?.phase == .finalizing, update.phase != .finalizing { return }
                        progress = update
                    }
                }
                await onInstalled()
                didFinish = true
            } catch {
                errorMessage = error.localizedDescription
                progress = nil
            }
        }
    }
}
