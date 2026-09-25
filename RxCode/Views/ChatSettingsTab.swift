import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

// MARK: - Chat Settings Tab

struct ChatSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var isRefreshingAgentStatus = false
    @State private var installingRuntime: AgentRuntimeInstaller.Runtime?
    @State private var signingInRuntime: AgentRuntimeInstaller.Runtime?
    @State private var claudeRequestedVersion = "latest"
    @State private var codexRequestedVersion = "latest"
    @State private var availableVersions: [AgentRuntimeInstaller.Runtime: [String]] = [:]
    @State private var loadingVersions: Set<AgentRuntimeInstaller.Runtime> = []
    @State private var versionErrors: [AgentRuntimeInstaller.Runtime: String] = [:]
    @State private var runtimeMessage: String?

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                agentRuntimeSection
                Divider()
                modelSection
                Divider()
                summarizationSection
                Divider()
                permissionModeSection
                Divider()
                effortSection
                Divider()
                focusModeSection
                Divider()
                autoPreviewSection
                Divider()
                archiveSection
                Divider()
                autoDeleteSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if claudeRequestedVersion == "latest",
               let installed = installedVersion(in: appState.claudeVersion) {
                claudeRequestedVersion = installed
            }
            if codexRequestedVersion == "latest",
               let installed = installedVersion(in: appState.codexVersion) {
                codexRequestedVersion = installed
            }
            async let claude: Void = loadVersions(for: .claude)
            async let codex: Void = loadVersions(for: .codex)
            _ = await (claude, codex)
        }
    }

    // MARK: - Agent Runtime Section

    private var agentRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent Runtimes")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

                Spacer()

                Button {
                    Task {
                        isRefreshingAgentStatus = true
                        await appState.refreshAgentInstallations()
                        isRefreshingAgentStatus = false
                    }
                } label: {
                    if isRefreshingAgentStatus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingAgentStatus)
                .help("Refresh installation status")
            }

            VStack(spacing: 8) {
                agentRuntimeRow(
                    runtime: .claude,
                    title: "Claude Code",
                    installed: appState.claudeInstalled,
                    version: appState.claudeVersion,
                    path: appState.claudeBinaryPath,
                    requestedVersion: $claudeRequestedVersion
                )
                agentRuntimeRow(
                    runtime: .codex,
                    title: "Codex",
                    installed: appState.codexInstalled,
                    version: appState.codexVersion,
                    path: appState.codexBinaryPath,
                    requestedVersion: $codexRequestedVersion
                )
            }
            Text("Downloads use npm and are stored in RxCode's application support folder. Choose a published stable version or Latest.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
            if let runtimeMessage {
                Text(runtimeMessage)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func agentRuntimeRow(
        runtime: AgentRuntimeInstaller.Runtime,
        title: String,
        installed: Bool,
        version: String?,
        path: String?,
        requestedVersion: Binding<String>
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
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
                }

                Text(path ?? "No executable detected")
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(path == nil ? .secondary : ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Picker("Version", selection: requestedVersion) {
                        Text("Latest").tag("latest")
                        ForEach(displayVersions(for: runtime, selected: requestedVersion.wrappedValue), id: \.self) { version in
                            Text(version).tag(version)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .accessibilityLabel("\(title) version")
                    if loadingVersions.contains(runtime) {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        install(runtime, version: requestedVersion.wrappedValue)
                    } label: {
                        if installingRuntime == runtime {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(installed ? "Install Version" : "Download")
                        }
                    }
                    .disabled(installingRuntime != nil)
                    if installed {
                        Button("Sign In") { signIn(runtime) }
                            .disabled(signingInRuntime != nil)
                        if signingInRuntime == runtime {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if path == AgentRuntimeInstaller.executablePath(for: runtime) {
                        Button("Remove") { remove(runtime) }
                            .disabled(installingRuntime != nil)
                    }
                }
                .controlSize(.small)
                if let error = versionErrors[runtime] {
                    HStack(spacing: 6) {
                        Text(error)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await loadVersions(for: runtime) }
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: ClaudeTheme.size(11)))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private func displayVersions(for runtime: AgentRuntimeInstaller.Runtime, selected: String) -> [String] {
        var versions = availableVersions[runtime] ?? []
        if selected != "latest" && !versions.contains(selected) {
            versions.insert(selected, at: 0)
        }
        return versions
    }

    private func installedVersion(in output: String?) -> String? {
        guard let output,
              let range = output.range(
                of: #"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"#,
                options: .regularExpression
              )
        else { return nil }
        return String(output[range])
    }

    private func loadVersions(for runtime: AgentRuntimeInstaller.Runtime) async {
        loadingVersions.insert(runtime)
        versionErrors[runtime] = nil
        defer { loadingVersions.remove(runtime) }
        do {
            availableVersions[runtime] = try await AgentVersionCatalog.shared.versions(for: runtime)
        } catch {
            versionErrors[runtime] = "Could not load published versions."
        }
    }

    private func install(_ runtime: AgentRuntimeInstaller.Runtime, version: String) {
        installingRuntime = runtime
        runtimeMessage = nil
        Task {
            defer { installingRuntime = nil }
            do {
                try await AgentRuntimeInstaller.shared.install(runtime, version: version)
                await appState.refreshAgentInstallations()
                runtimeMessage = "\(runtime == .claude ? "Claude Code" : "Codex") installed successfully."
            } catch {
                runtimeMessage = error.localizedDescription
            }
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
            } catch {
                runtimeMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Archive Section

    private var archiveSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Archive")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Inactive chats are moved to the archive automatically. Pinned chats are never auto-archived.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.autoArchiveEnabled) {
                Text("Auto-archive inactive chats")
            }
            .toggleStyle(.switch)
            .fixedSize()

            HStack(spacing: 10) {
                Text("Archive after")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: $appState.archiveRetentionDays,
                    in: 1...365
                ) {
                    Text("\(appState.archiveRetentionDays) day\(appState.archiveRetentionDays == 1 ? "" : "s") of inactivity")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                }
                .fixedSize()
            }
            .disabled(!appState.autoArchiveEnabled)
            .opacity(appState.autoArchiveEnabled ? 1 : 0.5)
        }
    }

    // MARK: - Auto-Delete Section

    private var autoDeleteSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Auto-delete")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Permanently delete archived chats after the retention window. Pinned chats are never auto-deleted. This cannot be undone.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.autoDeleteEnabled) {
                Text("Auto-delete archived chats")
            }
            .toggleStyle(.switch)
            .fixedSize()

            HStack(spacing: 10) {
                Text("Delete after")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: $appState.deleteRetentionDays,
                    in: 1...365
                ) {
                    Text("\(appState.deleteRetentionDays) day\(appState.deleteRetentionDays == 1 ? "" : "s") after archiving")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                }
                .fixedSize()
            }
            .disabled(!appState.autoDeleteEnabled)
            .opacity(appState.autoDeleteEnabled ? 1 : 0.5)
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default Model")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the model per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: defaultModelKey) {
                ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.key) { model in
                            Text(model.displayName).tag(model.key)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(selectedDefaultModel.description)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var defaultModelKey: Binding<String> {
        Binding(
            get: { "\(appState.selectedAgentProvider.rawValue):\(appState.selectedModel)" },
            set: { key in
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let provider = AgentProvider(rawValue: parts[0]) else { return }
                appState.selectedAgentProvider = provider
                appState.selectedModel = parts[1]
            }
        )
    }

    private var selectedDefaultModel: AgentModel {
        appState.availableAgentModelSections()
            .flatMap(\.models)
            .first { $0.provider == appState.selectedAgentProvider && $0.id == appState.selectedModel }
            ?? AgentModel(
                provider: appState.selectedAgentProvider,
                id: appState.selectedModel,
                displayName: appState.modelDisplayLabel(appState.selectedModel, provider: appState.selectedAgentProvider),
                description: AppState.modelDescription(appState.selectedModel, provider: appState.selectedAgentProvider)
            )
    }

    // MARK: - Summarization Section

    private var summarizationSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Summarization Model")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used to generate short session titles. The default follows each thread's model.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $appState.summarizationProvider) {
                ForEach(SummarizationProvider.availableCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .popoverTip(RxCodeTips.SummarizationModelTip(), arrowEdge: .trailing)
            .onChange(of: appState.summarizationProvider) { _, newValue in
                guard newValue == .openAI, appState.openAISummarizationModels.isEmpty else { return }
                Task { await appState.refreshOpenAISummarizationModels() }
            }

            switch appState.summarizationProvider {
            case .selectedClient:
                Text("Uses the model saved on the current thread.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            case .openAI:
                openAISummarizationForm
            case .appleFoundationModel:
                appleFoundationModelStatus
            }
        }
    }

    private var appleFoundationModelStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs on-device with Apple Intelligence. Private, free, and offline.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
            if let reason = FoundationModelSummarizationService.unavailabilityReason {
                Text(reason)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openAISummarizationForm: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 10) {
            settingsTextFieldRow(
                label: "Endpoint",
                text: $appState.openAISummarizationEndpoint,
                prompt: AppState.defaultOpenAISummarizationEndpoint
            )

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("API Key")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                SecureField("sk-...", text: $appState.openAISummarizationAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            }

            HStack(spacing: 10) {
                Picker("Model", selection: $appState.openAISummarizationModel) {
                    if !appState.openAISummarizationModel.isEmpty,
                       !appState.openAISummarizationModels.contains(appState.openAISummarizationModel)
                    {
                        Text(appState.openAISummarizationModel).tag(appState.openAISummarizationModel)
                    }
                    ForEach(appState.openAISummarizationModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    if appState.openAISummarizationModels.isEmpty && appState.openAISummarizationModel.isEmpty {
                        Text("Fetch models first").tag("")
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)

                Button {
                    Task { await appState.refreshOpenAISummarizationModels() }
                } label: {
                    if appState.isLoadingOpenAISummarizationModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Fetch Models", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(appState.isLoadingOpenAISummarizationModels)
            }

            if let error = appState.openAISummarizationModelsError {
                Text(error)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard appState.openAISummarizationModels.isEmpty else { return }
            Task { await appState.refreshOpenAISummarizationModels() }
        }
    }

    private func settingsTextFieldRow(label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
        }
    }

    // MARK: - Permission Mode Section

    private var permissionModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Permission Mode")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the permission mode per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.permissionMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(AppState.permissionModeDescription(appState.permissionMode))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Effort Section

    private var effortSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Effort Level")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the effort level per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.selectedEffort) {
                Text("Auto").tag("auto")
                ForEach(AppState.availableEfforts, id: \.self) { effort in
                    Text(effortDisplayName(effort)).tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(AppState.effortDescription(appState.selectedEffort))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Focus Mode Section

    private var focusModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Focus Mode")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("focus.mode.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.focusMode) {
                Text("Enable Focus Mode")
            }
            .toggleStyle(.switch)
            .fixedSize()
        }
    }

    // MARK: - Auto-Preview Attachments Section

    private var autoPreviewSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Auto-preview Attachments")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("auto.preview.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("URL links", isOn: $appState.autoPreviewSettings.url)
                Toggle("File paths", isOn: $appState.autoPreviewSettings.filePath)
                Toggle("Images", isOn: $appState.autoPreviewSettings.image)
                Toggle("Long text (200+ characters)", isOn: $appState.autoPreviewSettings.longText)
            }
            .toggleStyle(.checkbox)
        }
    }

    private func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return effort.capitalized
        }
    }
}
