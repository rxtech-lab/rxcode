import RxCodeCore
import SwiftUI

/// Mirrors `AgentRuntimeInstallSheet`: pick a published version, then install
/// it in place and show progress until the client is pinned and verified.
struct ACPVersionSheet: View {
    let selection: ACPVersionSelection
    let onInstall: (String, @escaping @Sendable (ACPInstallerService.Progress) -> Void) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var version: String
    @State private var publishedVersions: [String] = []
    @State private var isLoadingVersions = false
    @State private var versionLoadFailed = false
    @State private var isInstalling = false
    @State private var progress: ACPInstallerService.Progress?
    @State private var didFinish = false
    @State private var errorMessage: String?

    init(selection: ACPVersionSelection, onInstall: @escaping (String, @escaping @Sendable (ACPInstallerService.Progress) -> Void) async throws -> Void) {
        self.selection = selection
        self.onInstall = onInstall
        _version = State(initialValue: selection.initialVersion
            ?? selection.client?.installedVersion
            ?? selection.agent.version)
    }

    private var supportsExactVersions: Bool {
        selection.agent.distribution.npx != nil || selection.agent.distribution.uvx != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            versionPicker
            Color.clear.frame(height: 80)
            footer
        }
        .padding(20)
        .frame(width: 420)
        .overlay(alignment: .bottom) {
            if isInstalling || didFinish {
                progressSection
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
            }
        }
        .alert("Installation Failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(isInstalling)
        .task { await loadVersions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Install \(selection.agent.name)")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
            Text(selection.client?.installedVersion.map { "Currently installed: \($0)" } ?? "Not installed")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var versionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Version", selection: $version) {
                    ForEach(displayVersions, id: \.self) { release in
                        Text(release == selection.agent.version
                            ? "\(release) (registry release)" : release)
                            .tag(release)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isInstalling || didFinish)
                .accessibilityLabel("\(selection.agent.name) version")
                if isLoadingVersions {
                    ProgressView().controlSize(.small)
                }
            }
            Text(supportsExactVersions
                ? "Choose a published stable npm or PyPI release. RxCode will pin and verify it before saving."
                : "This client has a binary distribution only. The registry supplies a download for its current release.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if versionLoadFailed {
                HStack(spacing: 6) {
                    Text("Could not load published versions.")
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
            Text(didFinish
                ? "Installed \(selection.agent.name) \(version)."
                : progressLabel)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
            if let progress, progress.phase == .downloading {
                Text(byteCountLabel(progress))
                    .font(.system(size: ClaudeTheme.size(11)).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressLabel: String {
        switch progress?.phase {
        case .downloading: "Downloading \(version)…"
        case .extracting: "Extracting \(version)…"
        case .preparing: "Preparing client and discovering models…"
        case nil: "Installing \(version)…"
        }
    }

    private func byteCountLabel(_ progress: ACPInstallerService.Progress) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        let downloaded = formatter.string(fromByteCount: progress.downloadedBytes)
        guard let expected = progress.expectedBytes, expected > 0 else { return downloaded }
        return "\(downloaded) of \(formatter.string(fromByteCount: expected))"
    }

    private var footer: some View {
        HStack {
            Spacer()
            if didFinish {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isInstalling)
                Button {
                    install()
                } label: {
                    Text(isInstalling ? "Installing…" : "Install")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling
                    || !ACPPackageVersion.isValid(version)
                    || (!supportsExactVersions && version != selection.agent.version))
            }
        }
    }

    private var displayVersions: [String] {
        let initial = version == selection.agent.version
            ? [version] : [version, selection.agent.version]
        return initial + publishedVersions.filter { !initial.contains($0) }
    }

    private func loadVersions() async {
        guard supportsExactVersions else { return }
        isLoadingVersions = true
        versionLoadFailed = false
        defer { isLoadingVersions = false }
        do {
            publishedVersions = try await AgentVersionCatalog.shared.versions(for: selection.agent)
        } catch is CancellationError {
            return
        } catch {
            versionLoadFailed = true
        }
    }

    private func install() {
        isInstalling = true
        errorMessage = nil
        progress = nil
        let target = version
        Task {
            defer { isInstalling = false }
            do {
                try await onInstall(target) { update in
                    Task { @MainActor in
                        guard isInstalling, !didFinish else { return }
                        // Delegate callbacks may reach the main actor after extraction starts.
                        if progress?.phase == .preparing { return }
                        if progress?.phase == .extracting, update.phase == .downloading { return }
                        progress = update
                    }
                }
                didFinish = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Editor Sheet

struct ACPClientEditorSheet: View {
    @State var client: ACPClientSpec
    let refreshModels: (String) async -> ACPClientSpec?
    let onSave: (ACPClientSpec) -> Void
    let onCancel: () -> Void

    @State private var envKeyInput: String = ""
    @State private var envValueInput: String = ""
    @State private var isFetching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit ACP Client")
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))

            TextField("Display name", text: $client.displayName)
                .textFieldStyle(.roundedBorder)

            modelsSection

            VStack(alignment: .leading, spacing: 6) {
                Text("Extra environment")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                ForEach(Array(client.extraEnv.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        Text("=")
                            .foregroundStyle(.secondary)
                        Text(client.extraEnv[key] ?? "")
                            .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            client.extraEnv.removeValue(forKey: key)
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("KEY", text: $envKeyInput)
                        .textFieldStyle(.roundedBorder)
                    TextField("value", text: $envValueInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let k = envKeyInput.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }
                        client.extraEnv[k] = envValueInput
                        envKeyInput = ""
                        envValueInput = ""
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave(client) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Models")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                if client.modelConfigId != nil {
                    Text("Auto-detected")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 4) {
                        if isFetching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Fetch")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetching)
            }

            if client.models.isEmpty {
                HStack {
                    Text("Default")
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("This agent didn't advertise a model selector. The model picker shows a single \"Default\" entry — the agent picks its own model at runtime. Click Fetch to retry.")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.tertiary)
            } else {
                if modelRows.count > 10 {
                    ScrollView(.vertical) {
                        modelList
                            .padding(.trailing, 8)
                    }
                    .frame(height: 220)
                    .scrollIndicators(.visible)
                } else {
                    modelList
                }
                if client.modelConfigId != nil {
                    Text("This agent reports its models over ACP. RxCode refreshes the list every session start.")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(modelRows, id: \.value) { model in
                Text(model.name)
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var modelRows: [(value: String, name: String)] {
        if let options = client.modelOptions, !options.isEmpty {
            return options.map { option in
                (option.value, option.name.isEmpty ? option.value : option.name)
            }
        }
        return client.models.map { ($0, $0) }
    }

    private func fetchModels() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            defer { isFetching = false }
            if let updated = await refreshModels(client.id) {
                client = updated
            }
        }
    }
}
