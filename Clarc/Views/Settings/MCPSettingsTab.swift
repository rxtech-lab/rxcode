import SwiftUI
import ClarcCore

struct MCPSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var showEditor = false
    @State private var pendingRemoval: MCPServerInfo?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                contextBanner
                if let error = appState.mcpListError {
                    errorBanner(error)
                }
                ForEach(visibleScopes) { scope in
                    scopeSection(scope: scope)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if appState.mcpServers.isEmpty && !appState.mcpIsLoading {
                await appState.refreshMCPServers()
            }
        }
        .sheet(isPresented: $showEditor) {
            MCPServerEditorSheet { spec, scope in
                if let err = await appState.addMCPServer(spec: spec, scope: scope) {
                    actionError = err
                    return false
                }
                return true
            }
        }
        .alert("Remove MCP server?", isPresented: removalBinding, presenting: pendingRemoval) { server in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                let target = server
                pendingRemoval = nil
                Task {
                    if let err = await appState.removeMCPServer(name: target.name, scope: target.scope ?? .user) {
                        actionError = err
                    }
                }
            }
        } message: { server in
            Text(verbatim: "“\(server.name)” will be removed from the \(server.scope?.displayName ?? "User") scope.")
        }
        .alert("MCP error", isPresented: actionErrorBinding, presenting: actionError) { _ in
            Button("OK", role: .cancel) { actionError = nil }
        } message: { msg in
            Text(verbatim: msg)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Servers")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                Text("Configure Model Context Protocol servers used by Claude Code.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await appState.refreshAndProbeAllMCPServers() }
            } label: {
                Image(systemName: appState.mcpIsLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.bordered)
            .disabled(appState.mcpIsLoading)
            .help("Refresh & Test All")

            Button {
                showEditor = true
            } label: {
                Label("Add Server", systemImage: "plus")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(verbatim: message)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Context filtering

    /// When a project is active, only project-scoped MCPs (Local/Project for the
    /// current path) are shown. Otherwise, only User-scope (global) MCPs are shown.
    private var visibleScopes: [MCPScope] {
        appState.activeProjectPath != nil ? [.local, .project] : [.user]
    }

    private func servers(in scope: MCPScope) -> [MCPServerInfo] {
        appState.mcpServers.filter { server in
            guard (server.scope ?? .user) == scope else { return false }
            if let activePath = appState.activeProjectPath {
                return server.projectPath == activePath
            }
            return true
        }
    }

    @ViewBuilder
    private var contextBanner: some View {
        if let path = appState.activeProjectPath, !path.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Text("Showing MCPs for this project")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Text(verbatim: displayPath(path))
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Text("Showing global MCPs only")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    // MARK: - Scope section

    private func scopeSection(scope: MCPScope) -> some View {
        let servers = servers(in: scope)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(scope.displayName))
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text(LocalizedStringKey(scope.subtitle))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }

            if servers.isEmpty {
                Text("No servers")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(servers) { server in
                        MCPServerRow(
                            server: server,
                            probe: appState.mcpProbeResults[server.id],
                            isProbing: appState.mcpInFlightProbes.contains(server.id),
                            onTest: { Task { await appState.probeMCPServer(info: server) } },
                            onRemove: { pendingRemoval = server }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }
}

// MARK: - Row

private struct MCPServerRow: View {
    let server: MCPServerInfo
    let probe: MCPProbeResult?
    let isProbing: Bool
    let onTest: () -> Void
    let onRemove: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(verbatim: server.name)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        transportBadge
                    }
                    Text(verbatim: server.endpoint)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let projectPath = server.projectPath, !projectPath.isEmpty {
                        Text(verbatim: projectDisplayPath(projectPath))
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)

                Button(action: onTest) {
                    if isProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                            .font(.system(size: ClaudeTheme.size(11)))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isProbing)

                Menu {
                    Button("Reconnect", action: onTest)
                    if probe != nil {
                        Button(expanded ? "Hide Tools" : "View Tools") { expanded.toggle() }
                    }
                    Divider()
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: ClaudeTheme.size(12)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded, let probe {
                Divider()
                probeDetail(probe)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var statusDot: some View {
        let (color, label) = statusColorAndLabel
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(label)
    }

    private var statusColorAndLabel: (Color, String) {
        switch server.status {
        case .connected:        return (.green, "Connected")
        case .needsAuth:        return (.orange, "Needs authentication")
        case .failed(let msg):  return (.red, msg)
        case .unknown:          return (.gray, "Unknown")
        }
    }

    private func projectDisplayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private var transportBadge: some View {
        Text(verbatim: server.transport.displayName)
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func probeDetail(_ probe: MCPProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = probe.error, !probe.ok {
                Text(verbatim: error)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.red)
            } else {
                if let serverName = probe.serverName {
                    let suffix = probe.serverVersion.map { " v\($0)" } ?? ""
                    Text(verbatim: "Server: \(serverName)\(suffix)")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                if probe.tools.isEmpty {
                    Text("No tools advertised.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "\(probe.tools.count) tools")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    ForEach(probe.tools) { tool in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: tool.name)
                                .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                            if let description = tool.description, !description.isEmpty {
                                Text(verbatim: description)
                                    .font(.system(size: ClaudeTheme.size(10)))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            }
        }
    }
}
