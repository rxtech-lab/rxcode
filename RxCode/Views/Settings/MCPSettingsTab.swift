import SwiftUI
import RxCodeCore
import RxCodeChatKit
import TipKit

struct MCPSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var showEditor = false
    @State private var authenticationServer: MCPServerInfo?
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
                serverSection
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
                    return MCPProbeResult(ok: false, error: err)
                }
                guard let server = appState.mcpServers.first(where: { $0.name == spec.name }),
                      let result = appState.mcpProbeResults[server.id] else {
                    return MCPProbeResult(ok: false, error: "The saved MCP server could not be tested. Try saving again.")
                }
                return result
            }
        }
        .sheet(item: $authenticationServer) { server in
            MCPOAuthSheet(server: server) { await appState.probeMCPServer(info: server) }
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
            Text(verbatim: "“\(server.name)” will be removed from RxCode MCP settings.")
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
                Text("Configure Model Context Protocol servers used by Claude Code, Codex, and ACP clients.")
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
            .popoverTip(RxCodeTips.MCPTip(), arrowEdge: .top)
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

    @ViewBuilder
    private var contextBanner: some View {
        if let path = appState.activeProjectPath, !path.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Text("Showing effective MCP state for this project")
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
                Text("Showing global MCP defaults")
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

    // MARK: - Server section

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("Servers")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Global default plus per-project override")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }

            if appState.mcpServers.isEmpty {
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
                    ForEach(appState.mcpServers) { server in
                        MCPServerRow(
                            server: server,
                            projectPath: appState.activeProjectPath,
                            probe: appState.mcpProbeResults[server.id],
                            isProbing: appState.mcpInFlightProbes.contains(server.id),
                            onTest: { Task { await appState.probeMCPServer(info: server) } },
                            onAuthenticate: { authenticationServer = server },
                            onGlobalEnabledChange: { enabled in
                                Task {
                                    if let err = await appState.setMCPServerGlobalEnabled(name: server.name, enabled: enabled) {
                                        actionError = err
                                    }
                                }
                            },
                            onProjectOverrideChange: { override in
                                Task {
                                    if let err = await appState.setMCPServerProjectOverride(name: server.name, override: override) {
                                        actionError = err
                                    }
                                }
                            },
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
    let projectPath: String?
    let probe: MCPProbeResult?
    let isProbing: Bool
    let onTest: () -> Void
    let onAuthenticate: () -> Void
    let onGlobalEnabledChange: (Bool) -> Void
    let onProjectOverrideChange: (MCPProjectOverride) -> Void
    let onRemove: () -> Void

    @State private var showDetails = false

    private var inProject: Bool { projectPath != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(verbatim: server.name)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        transportBadge
                        if inProject && server.projectOverride != .inherit {
                            overrideBadge
                        }
                    }
                    Text(verbatim: server.endpoint)
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(scopeDescription)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)

                if isProbing {
                    ProgressView().controlSize(.small)
                }

                Toggle("", isOn: effectiveBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(toggleHelp)

                Menu {
                    if server.transport != .stdio {
                        Button("Authentication…", systemImage: "person.crop.circle.badge.checkmark", action: onAuthenticate)
                    }
                    Button(isProbing ? "Testing…" : "Test connection", action: onTest)
                        .disabled(isProbing || !server.effectiveEnabled)
                    if probe != nil {
                        Button("View details") { showDetails = true }
                    }

                    if inProject {
                        Divider()
                        Section("This project") {
                            Picker("Override", selection: overrideBinding) {
                                Text("Inherit global default").tag(MCPProjectOverride.inherit)
                                Text("Force on").tag(MCPProjectOverride.enabled)
                                Text("Force off").tag(MCPProjectOverride.disabled)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        Section("Global default") {
                            Button(server.isGloballyEnabled ? "Disable globally" : "Enable globally") {
                                onGlobalEnabledChange(!server.isGloballyEnabled)
                            }
                        }
                    }

                    Divider()
                    Button("Remove…", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .sheet(isPresented: $showDetails) {
            MCPServerDetailsSheet(server: server, probe: probe)
        }
    }

    // MARK: - Bindings

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { server.effectiveEnabled },
            set: { newValue in
                if inProject {
                    onProjectOverrideChange(newValue ? .enabled : .disabled)
                } else {
                    onGlobalEnabledChange(newValue)
                }
            }
        )
    }

    private var overrideBinding: Binding<MCPProjectOverride> {
        Binding(
            get: { server.projectOverride },
            set: { onProjectOverrideChange($0) }
        )
    }

    // MARK: - Labels

    private var toggleHelp: String {
        if inProject {
            return server.effectiveEnabled
                ? "Turn off for this project"
                : "Turn on for this project"
        }
        return server.effectiveEnabled ? "Disable globally" : "Enable globally"
    }

    private var scopeDescription: String {
        guard inProject else {
            return server.isGloballyEnabled
                ? String(localized: "Global default · On")
                : String(localized: "Global default · Off")
        }
        switch server.projectOverride {
        case .inherit:
            return server.isGloballyEnabled
                ? String(localized: "Inherits global default (On)")
                : String(localized: "Inherits global default (Off)")
        case .enabled:
            return String(localized: "Forced on for this project")
        case .disabled:
            return String(localized: "Forced off for this project")
        }
    }

    private var overrideBadge: some View {
        Text(server.projectOverride == .enabled ? "Project: On" : "Project: Off")
            .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help("Project-specific override is set")
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

    private var transportBadge: some View {
        Text(verbatim: server.transport.displayNameText)
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

}

private struct MCPServerDetailsSheet: View {
    let server: MCPServerInfo
    let probe: MCPProbeResult?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedTool: MCPTool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(ClaudeTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(ClaudeTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: server.name).font(.headline)
                    Text("MCP Server Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: server.endpoint)
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(verbatim: server.transport.displayNameText)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    if let name = probe?.serverName {
                        Text(verbatim: name + (probe?.serverVersion.map { " · v\($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: "\(probe?.tools.count ?? 0) tools")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                TextField("Search tools", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search tools")
            }
            .padding(20)
            Divider()

            if let probe, !probe.ok, let error = probe.error {
                ContentUnavailableView {
                    Label("Connection failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: error).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let probe {
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let tools = probe.tools.filter {
                    query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                        || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
                }
                if tools.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No tools advertised" : "No matching tools",
                        systemImage: "wrench.and.screwdriver",
                        description: Text(query.isEmpty ? "This server has not advertised any tools." : "Try a different name or keyword.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(tools) { tool in
                                Button { selectedTool = tool } label: {
                                    HStack {
                                        Text(verbatim: tool.name)
                                            .font(.system(size: ClaudeTheme.size(13), weight: .semibold, design: .monospaced))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(Color(NSColor.separatorColor).opacity(0.5))
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("View description and schemas")
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No connection details", systemImage: "server.rack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 680)
        .sheet(item: $selectedTool) { tool in
            MCPToolDetailsSheet(tool: tool)
        }
    }
}

private struct MCPToolDetailsSheet: View {
    let tool: MCPTool
    @Environment(\.dismiss) private var dismiss
    @State private var section = Section.description

    private enum Section: String, CaseIterable {
        case description = "Description"
        case input = "Input"
        case output = "Output"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: tool.name)
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Picker("Tool details", selection: $section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            Divider()
            if let content {
                ScrollView {
                    MarkdownContentView(text: content, style: .rxCodeCompact)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    section == .description ? "No description" : "No schema provided",
                    systemImage: "doc.text",
                    description: Text(section == .description
                        ? "The server did not provide a description for this tool."
                        : "The server did not advertise an \(section.rawValue.lowercased()) schema for this tool.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 640)
    }

    private var content: String? {
        if section == .description {
            guard let description = tool.description, !description.isEmpty else { return nil }
            return description
        }
        guard let schema = section == .input ? tool.inputSchema : tool.outputSchema else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(schema), let json = String(data: data, encoding: .utf8) else { return nil }
        return "```json\n" + json + "\n```"
    }
}
