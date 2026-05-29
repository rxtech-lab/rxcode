import RxCodeCore
import SwiftUI

struct ACPSetupPreview: View {
    let appState: AppState
    @Binding var installingAgentId: String?
    @Binding var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("ACP Clients")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if appState.acpRegistryLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await appState.refreshACPRegistry(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey("Refresh registry"))
                }
            }

            Text("Install additional ACP-compatible agents — RxCode downloads the right binary for macOS and probes the model list.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))

            ScrollView {
                VStack(spacing: 8) {
                    if let agents = appState.acpRegistry?.agents, !agents.isEmpty {
                        ForEach(agents.prefix(6)) { agent in
                            registryRow(agent)
                        }
                    } else if appState.acpRegistryLoading {
                        Text("Loading registry…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.54))
                    } else {
                        Text("Could not load registry. Check your network connection.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                }
            }
            .frame(maxHeight: 170)

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .lineLimit(2)
            }
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
        .task {
            if appState.acpRegistry == nil && !appState.acpRegistryLoading {
                await appState.refreshACPRegistry()
            }
        }
    }

    private func registryRow(_ agent: ACPRegistryAgent) -> some View {
        let alreadyInstalled = appState.acpClients.contains { $0.registryId == agent.id }
        let isInstalling = installingAgentId == agent.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: "v\(agent.version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(verbatim: agent.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Group {
                if alreadyInstalled {
                    Text("Installed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                } else if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        install(agent)
                    } label: {
                        Text("Add")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 56, height: 24)
                            .foregroundStyle(.white)
                            .background(ClaudeTheme.accent.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(installingAgentId != nil)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func install(_ agent: ACPRegistryAgent) {
        installingAgentId = agent.id
        errorMessage = nil
        Task {
            defer { installingAgentId = nil }
            do {
                let spec = try await appState.installACPClient(from: agent)
                appState.addACPClient(spec)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
