import SwiftUI
import RxCodeCore
import RxCodeSync

/// Manage ACP agent clients on the paired desktop: toggle/remove installed
/// clients and install new ones from the agentclientprotocol.com registry.
struct MobileACPClientsView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var pendingUninstall: MobileACPClient?

    var body: some View {
        List {
            if let error = state.acpRegistryError {
                errorRow(error)
            }
            if let error = state.lastACPError {
                errorRow(error)
            }

            installedSection
            registrySection
        }
        .navigationTitle("Agent Clients")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if state.acpRegistryLoading {
                    ProgressView()
                }
            }
        }
        .refreshable {
            await state.requestACPRegistry(forceRefresh: true)
        }
        .task {
            if state.acpRegistryAgents.isEmpty, state.acpInstalledClients.isEmpty {
                await state.requestACPRegistry()
            }
        }
        .alert(
            "Remove agent?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let client = pendingUninstall {
                    Task { await state.uninstallACPClient(client.id) }
                }
                pendingUninstall = nil
            }
        } message: {
            if let client = pendingUninstall {
                Text("This removes \(client.displayName) and its downloaded binary from your Mac.")
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !state.acpInstalledClients.isEmpty {
            Section("Installed") {
                ForEach(state.acpInstalledClients) { client in
                    installedRow(client)
                }
            }
        }
    }

    private func installedRow(_ client: MobileACPClient) -> some View {
        HStack(spacing: 12) {
            agentIcon(client.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName).font(.headline)
                Text("\(client.launchKind) · \(client.modelCount) model\(client.modelCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.inFlightACPMutations.contains(client.id) {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(
                    get: { client.enabled },
                    set: { value in Task { await state.setACPClientEnabled(client.id, enabled: value) } }
                ))
                .labelsHidden()
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                pendingUninstall = client
            }
        }
    }

    @ViewBuilder
    private var registrySection: some View {
        let available = state.acpRegistryAgents.filter { !$0.isInstalled }
        if !available.isEmpty {
            Section("Available in Registry") {
                ForEach(available) { agent in
                    registryRow(agent)
                }
            }
        } else if state.acpInstalledClients.isEmpty,
                  !state.acpRegistryLoading,
                  state.acpRegistryError == nil {
            Section {
                Text("No agents found.").foregroundStyle(.secondary)
            }
        }
    }

    private func registryRow(_ agent: MobileACPRegistryAgent) -> some View {
        HStack(spacing: 12) {
            agentIcon(agent.iconURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agent.name).font(.headline)
                    Text(agent.version).font(.caption).foregroundStyle(.tertiary)
                }
                if !agent.summary.isEmpty {
                    Text(agent.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let dist = distributionLabel(agent) {
                    Text(dist).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if state.inFlightACPMutations.contains(agent.id) {
                VStack(spacing: 2) {
                    ProgressView()
                    Text("Installing…").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button("Install") {
                    Task { await state.installACPAgent(agent.id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func distributionLabel(_ agent: MobileACPRegistryAgent) -> String? {
        var kinds: [String] = []
        if agent.hasBinary { kinds.append("binary") }
        if agent.hasNpx { kinds.append("npx") }
        if agent.hasUvx { kinds.append("uvx") }
        return kinds.isEmpty ? nil : kinds.joined(separator: " · ")
    }

    private func agentIcon(_ urlString: String?) -> some View {
        MobileACPIconView(url: urlString, size: 28)
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}
