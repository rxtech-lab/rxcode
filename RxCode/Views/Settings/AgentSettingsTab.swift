import RxCodeCore
import SwiftUI
import TipKit

struct ACPVersionSelection: Identifiable {
    let agent: ACPRegistryAgent
    let client: ACPClientSpec?
    var initialVersion: String?

    var id: String {
        client?.id ?? agent.id
    }
}

struct AgentSettingsTab: View {
    @Environment(AppState.self) private var appState

    let catalog: Bool

    init(catalog: Bool = false) {
        self.catalog = catalog
    }

    @Environment(\.dismiss) private var dismiss
    @State private var showInstall = false
    @State private var managingClient: ACPClientSpec?
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
    @State private var signOutError: String?
    @State private var cursorLogout: InteractiveTerminalState?
    @State private var cursorLogoutClientID: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    AgentRuntimeSettingsView(catalog: catalog)
                    if catalog {
                        registrySection(availableHeight: max(0, geometry.size.height - 270))
                    } else if appState.claudeInstalled || appState.codexInstalled || !appState.acpClients.isEmpty {
                        installedSection
                    } else {
                        ContentUnavailableView("No Agents Installed", systemImage: "person.crop.rectangle.stack",
                                               description: Text("Install Claude Code, Codex, or a client from the ACP registry."))
                            .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 150))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            if signingOutClientID != nil || signOutMessage != nil {
                HStack(spacing: 8) {
                    if signingOutClientID != nil { ProgressView().controlSize(.small) }
                    Text(signOutMessage ?? "Signing out…")
                    if signOutMessage != nil {
                        Button("Dismiss") { signOutMessage = nil }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .alert("Sign-out Failed", isPresented: Binding(
            get: { signOutError != nil }, set: { if !$0 { signOutError = nil } },
        )) {
            Button("OK", role: .cancel) { signOutError = nil }
        } message: {
            Text(signOutError ?? "")
        }
        .task { await appState.refreshAgentInstallations() }
        .task {
            if appState.acpRegistry == nil, !appState.acpRegistryLoading {
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
        .sheet(isPresented: $showInstall) {
            AgentSettingsTab(catalog: true)
                .frame(width: 620, height: 560)
        }
        .sheet(item: $managingClient) { client in
            managementSheet(appState.acpClients.first { $0.id == client.id } ?? client)
                .overlay(alignment: .bottom) {
                    if signingOutClientID != nil || signOutMessage != nil {
                        HStack(spacing: 8) {
                            if signingOutClientID != nil { ProgressView().controlSize(.small) }
                            Text(signOutMessage ?? "Signing out…")
                            if signOutMessage != nil {
                                Button("Dismiss") { signOutMessage = nil }
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                    }
                }
                .alert("Sign-out Failed", isPresented: Binding(
                    get: { signOutError != nil }, set: { if !$0 { signOutError = nil } },
                )) {
                    Button("OK", role: .cancel) { signOutError = nil }
                } message: {
                    Text(signOutError ?? "")
                }

                .sheet(item: $cursorLogout, onDismiss: { cursorLogoutClientID = nil }) { state in
                    ACPTerminalSignInSheet(state: state) {
                        guard let clientID = cursorLogoutClientID else { return }
                        cursorLogout = nil
                        signingOutClientID = clientID
                        Task {
                            defer { signingOutClientID = nil }
                            await appState.completeACPTerminalLogout(id: clientID)
                            await refreshSignInStatuses()
                            signOutMessage = "Signed out of Cursor."
                        }
                    }
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
                            signOutMessage = "Client updated."
                        },
                        onCancel: { editingClient = nil },
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
                        managingClient = nil
                        signOutMessage = "Client removed."
                    }
                } message: { client in
                    Text(verbatim: "“\(client.displayName)” will be removed from RxCode.")
                }
        }
        .sheet(item: Binding(
            get: { catalog ? versionSelection : nil },
            set: { versionSelection = $0 },
        )) { selection in
            ACPVersionSheet(selection: selection) { version in
                try await install(selection, version: version)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(catalog ? "Install Client" : "Agent")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                Text(catalog ? "Choose Claude Code, Codex, or an ACP registry client." : "Manage your installed agent runtimes and accounts.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if catalog {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button {
                    Task { await appState.refreshAgentInstallations() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh installation status")
                Button("Install Client…") { showInstall = true }
                    .buttonStyle(.borderedProminent)
                    .popoverTip(RxCodeTips.ACPTip(), arrowEdge: .top)
            }
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !appState.acpClients.isEmpty {
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

            if let agent = registryAgent(for: client), installingAgentId == agent.id {
                ProgressView().controlSize(.small)
            }
            Button("Manage…") { managingClient = client }
                .controlSize(.small)
                .disabled(installingAgentId != nil || signingOutClientID == client.id)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1),
        )
    }

    private func managementSheet(_ client: ACPClientSpec) -> some View {
        let isSignedIn = signedInClientIDs.contains(client.id)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Manage \(client.displayName)").font(.headline)
            Form {
                Toggle("Enabled", isOn: Binding(
                    get: { client.enabled },
                    set: { newValue in
                        var updated = client
                        updated.enabled = newValue
                        appState.updateACPClient(updated)
                        signOutMessage = newValue ? "Client enabled." : "Client disabled."
                    },
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                if let agent = registryAgent(for: client) {
                    Button("Install Version…") {
                        versionSelection = ACPVersionSelection(agent: agent, client: client)
                    }
                    if hasUpdate(client, agent: agent) {
                        Button("Update to \(agent.version)…") {
                            versionSelection = ACPVersionSelection(
                                agent: agent,
                                client: client,
                                initialVersion: agent.version,
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
            }
            .disabled(installingAgentId != nil || signingOutClientID != nil)
            HStack {
                Spacer()
                Button("Done") { managingClient = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(installingAgentId != nil || signingOutClientID != nil)
            }
        }
        .padding(24)
        .frame(width: 460, height: 400)
        .interactiveDismissDisabled(installingAgentId != nil || signingOutClientID != nil)
    }

    // MARK: - Registry

    private func registrySection(availableHeight: CGFloat) -> some View {
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
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1),
                )

                Text(registrySearch.isEmpty
                    ? "\(agents.count) agents available"
                    : "\(filtered.count) of \(agents.count) agents")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)

                if filtered.isEmpty {
                    ContentUnavailableView.search(text: registrySearch)
                        .frame(maxWidth: .infinity, minHeight: availableHeight)
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
                ContentUnavailableView("Registry Unavailable", systemImage: "network",
                    description: Text("Check your network connection and refresh the registry."))
                    .frame(maxWidth: .infinity, minHeight: availableHeight)
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
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1),
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
                if ACPService.isCursorClient(client) {
                    cursorLogoutClientID = client.id
                    cursorLogout = try await appState.acpCursorTerminalLogout(id: client.id)
                    return
                }
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
                signOutError = error.localizedDescription
            }
        }
    }

    // MARK: - Binding Helpers

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
}
