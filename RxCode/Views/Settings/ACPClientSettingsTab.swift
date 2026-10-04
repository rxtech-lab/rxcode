import SwiftUI
import RxCodeCore
import TipKit

private enum ACPClientSettingsPage: String, CaseIterable, Identifiable {
    case installed
    case registry

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .installed: return "Installed"
        case .registry: return "Registry"
        }
    }
}

private struct ACPVersionSelection: Identifiable {
    let agent: ACPRegistryAgent
    let client: ACPClientSpec?
    var initialVersion: String? = nil

    var id: String { client?.id ?? agent.id }
}

struct ACPClientSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var selectedPage: ACPClientSettingsPage = .installed
    @State private var pendingRemoval: ACPClientSpec?
    @State private var editingClient: ACPClientSpec?
    @State private var registrySearch: String = ""
    @State private var installingAgentId: String?
    @State private var versionSelection: ACPVersionSelection?
    @State private var signInClient: ACPClientSpec?
    @State private var signedInClientIDs: Set<String> = []
    @State private var logoutClientIDs: Set<String> = []
    @State private var signingOutClientID: String?
    @State private var signOutMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                pagePicker
                Divider()
                switch selectedPage {
                case .installed:
                    installedSection
                case .registry:
                    registrySection
                }
                if let signOutMessage {
                    Text(signOutMessage)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if appState.acpRegistry == nil && !appState.acpRegistryLoading {
                await appState.refreshACPRegistry()
            }
        }
        .task { await refreshSignInStatuses() }
        .onChange(of: appState.acpClients) { _, _ in
            Task { await refreshSignInStatuses() }
        }
        .onChange(of: signInClient) { _, client in
            if client == nil { Task { await refreshSignInStatuses() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSignInStatuses() }
        }
        .onChange(of: selectedPage) { _, page in
            guard page == .registry,
                  appState.acpRegistry == nil,
                  !appState.acpRegistryLoading
            else { return }
            Task { await appState.refreshACPRegistry() }
        }
        .sheet(item: $editingClient) { client in
            ACPClientEditorSheet(
                client: client,
                refreshModels: { id in
                    await appState.refreshACPClientModels(id: id)
                    return appState.acpClients.first { $0.id == id }
                },
                onSave: { updated in
                    appState.updateACPClient(updated)
                    editingClient = nil
                },
                onCancel: { editingClient = nil }
            )
        }
        .sheet(item: $versionSelection) { selection in
            ACPVersionSheet(selection: selection) { version in
                try await install(selection, version: version)
            }
        }
        .sheet(item: $signInClient) { client in
            ACPSignInSheet(client: client, isSignedIn: signedInClientIDs.contains(client.id))
        }
        .alert("Remove ACP client?", isPresented: removalBinding, presenting: pendingRemoval) { client in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                appState.removeACPClient(id: client.id)
                pendingRemoval = nil
            }
        } message: { client in
            Text(verbatim: "“\(client.displayName)” will be removed from RxCode.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACP Clients")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
            Text("Manage agents that speak the Agent Client Protocol. Detected from agentclientprotocol.com.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var pagePicker: some View {
        Picker("ACP page", selection: $selectedPage) {
            ForEach(ACPClientSettingsPage.allCases) { page in
                Text(page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .frame(maxWidth: .infinity, alignment: .center)
        .popoverTip(RxCodeTips.ACPTip(), arrowEdge: .top)
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installed")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            if appState.acpClients.isEmpty {
                Text("No clients installed. Add one from the Registry tab.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(appState.acpClients) { client in
                        installedRow(client)
                    }
                }
            }
        }
    }

    private func installedRow(_ client: ACPClientSpec) -> some View {
        let isSignedIn = signedInClientIDs.contains(client.id)
        return HStack(alignment: .top, spacing: 12) {
            ACPIconView(url: client.iconURL, size: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(client.displayName)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text(client.launch.displayKind)
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                    if isSignedIn {
                        Text("Signed In")
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                    Spacer(minLength: 0)
                }
                Text(modelSummary(for: client))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let version = client.installedVersion {
                        Text(ACPPackageVersion.isPinned(client.launch, to: version)
                             ? "Version \(version)" : "Version \(version) (not pinned)")
                            .foregroundStyle(.secondary)
                    }
                    if let agent = registryAgent(for: client), hasUpdate(client, agent: agent) {
                        Text("Update available: \(agent.version)")
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                }
                .font(.system(size: ClaudeTheme.size(10)))
            }

            Toggle("", isOn: Binding(
                get: { client.enabled },
                set: { newValue in
                    var updated = client
                    updated.enabled = newValue
                    appState.updateACPClient(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            if let agent = registryAgent(for: client), installingAgentId == agent.id {
                ProgressView().controlSize(.small)
            }
            Menu {
                if let agent = registryAgent(for: client) {
                    Button("Install Version…") {
                        versionSelection = ACPVersionSelection(agent: agent, client: client)
                    }
                    if hasUpdate(client, agent: agent) {
                        Button("Update to \(agent.version)…") {
                            versionSelection = ACPVersionSelection(
                                agent: agent,
                                client: client,
                                initialVersion: agent.version
                            )
                        }
                    }
                    Divider()
                }
                Button(isSignedIn ? LocalizedStringKey("Re-sign In…") : LocalizedStringKey("Sign In…")) {
                    signInClient = client
                }
                if logoutClientIDs.contains(client.id) {
                    Button("Sign Out") { signOut(client) }
                        .disabled(signingOutClientID != nil)
                }
                Button("Edit…") { editingClient = client }
                Divider()
                Button("Remove", role: .destructive) { pendingRemoval = client }
            } label: {
                Text("Manage")
            }
            .menuStyle(.button)
            .fixedSize()
            .controlSize(.small)
            .disabled(installingAgentId != nil || signingOutClientID == client.id)
            .accessibilityLabel("\(client.displayName) actions")
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Registry

    private var registrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Registry")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Spacer()
                Button {
                    Task { await appState.refreshACPRegistry(forceRefresh: true) }
                } label: {
                    if appState.acpRegistryLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(appState.acpRegistryLoading)
                .help("Refresh registry")
            }

            if let agents = appState.acpRegistry?.agents, !agents.isEmpty {
                let filtered = filteredAgents(agents)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: ClaudeTheme.size(11)))
                    TextField("Search agents", text: $registrySearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: ClaudeTheme.size(12)))
                    if !registrySearch.isEmpty {
                        Button {
                            registrySearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )

                Text(registrySearch.isEmpty
                     ? "\(agents.count) agents available"
                     : "\(filtered.count) of \(agents.count) agents")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)

                if filtered.isEmpty {
                    Text("No agents match “\(registrySearch)”.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filtered) { agent in
                            registryRow(agent)
                        }
                    }
                }
            } else if appState.acpRegistryLoading {
                Text("Loading registry…")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            } else {
                Text("Could not load registry. Check your network connection.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func registryRow(_ agent: ACPRegistryAgent) -> some View {
        let alreadyInstalled = appState.acpClients.contains { $0.registryId == agent.id }
        let isInstalling = installingAgentId == agent.id
        return HStack(alignment: .top, spacing: 12) {
            ACPIconView(url: agent.icon, size: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text("v\(agent.version)")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                    if let license = agent.license {
                        Text(license)
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(agent.description)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(distributionSummary(agent.distribution))
                    .font(.system(size: ClaudeTheme.size(10), design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if alreadyInstalled {
                Text("Installed")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                    .padding(.top, 2)
            } else if isInstalling {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else {
                Button("Add…") {
                    versionSelection = ACPVersionSelection(agent: agent, client: nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(installingAgentId != nil)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private func install(_ selection: ACPVersionSelection, version: String) async throws {
        installingAgentId = selection.agent.id
        defer { installingAgentId = nil }
        if let client = selection.client {
            try await appState.updateACPClient(id: client.id, from: selection.agent, version: version)
        } else {
            let spec = try await appState.installACPClient(from: selection.agent, version: version)
            appState.addACPClient(spec)
        }
    }

    private func registryAgent(for client: ACPClientSpec) -> ACPRegistryAgent? {
        guard let registryId = client.registryId else { return nil }
        return appState.acpRegistry?.agents.first { $0.id == registryId }
    }

    private func hasUpdate(_ client: ACPClientSpec, agent: ACPRegistryAgent) -> Bool {
        client.installedVersion != agent.version
            || !ACPPackageVersion.isPinned(client.launch, to: agent.version)
    }

    private func filteredAgents(_ agents: [ACPRegistryAgent]) -> [ACPRegistryAgent] {
        let query = registrySearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return agents }
        return agents.filter { agent in
            if agent.name.lowercased().contains(query) { return true }
            if agent.id.lowercased().contains(query) { return true }
            if agent.description.lowercased().contains(query) { return true }
            return false
        }
    }

    private func distributionSummary(_ dist: ACPDistribution) -> String {
        var parts: [String] = []
        if let npx = dist.npx { parts.append("npx \(npx.package)") }
        if let uvx = dist.uvx { parts.append("uvx \(uvx.package)") }
        if let bin = dist.binary, !bin.isEmpty {
            parts.append("binary (\(bin.keys.sorted().joined(separator: ", ")))")
        }
        return parts.joined(separator: " · ")
    }

    private func modelSummary(for client: ACPClientSpec) -> String {
        if let options = client.modelOptions, !options.isEmpty {
            return options.map { $0.name.isEmpty ? $0.value : $0.name }.joined(separator: ", ")
        }
        return client.models.isEmpty ? "Default (agent-chosen)" : client.models.joined(separator: ", ")
    }

    private func refreshSignInStatuses() async {
        var signedIn: Set<String> = []
        var canLogOut: Set<String> = []
        for client in appState.acpClients {
            if await appState.isACPClientSignedIn(client) {
                signedIn.insert(client.id)
            }
            if await appState.acpClientSupportsLogout(client) {
                canLogOut.insert(client.id)
            }
        }
        guard !Task.isCancelled else { return }
        signedInClientIDs = signedIn
        logoutClientIDs = canLogOut
    }

    private func signOut(_ client: ACPClientSpec) {
        signingOutClientID = client.id
        signOutMessage = nil
        Task {
            defer { signingOutClientID = nil }
            do {
                let terminalOpened = try await appState.signOutACPClient(id: client.id)
                if terminalOpened {
                    signOutMessage = "Choose the provider to sign out in Terminal."
                    return
                }
                signedInClientIDs.remove(client.id)
                logoutClientIDs.remove(client.id)
                await refreshSignInStatuses()
                signOutMessage = signedInClientIDs.contains(client.id)
                    ? "Stored sign-in cleared, but \(client.displayName) still has credentials from its environment."
                    : "Signed out of \(client.displayName)."
            } catch {
                signOutMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Binding Helpers

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
}

/// Mirrors `AgentRuntimeInstallSheet`: pick a published version, then install
/// it in place and show progress until the client is pinned and verified.
private struct ACPVersionSheet: View {
    let selection: ACPVersionSelection
    let onInstall: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var version: String
    @State private var publishedVersions: [String] = []
    @State private var isLoadingVersions = false
    @State private var versionLoadFailed = false
    @State private var isInstalling = false
    @State private var didFinish = false
    @State private var errorMessage: String?

    init(selection: ACPVersionSelection, onInstall: @escaping (String) async throws -> Void) {
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
            if isInstalling || didFinish {
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
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(didFinish
                 ? "Installed \(selection.agent.name) \(version)."
                 : "Installing \(version)…")
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
        let target = version
        Task {
            defer { isInstalling = false }
            do {
                try await onInstall(target)
                didFinish = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Editor Sheet

private struct ACPClientEditorSheet: View {
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
