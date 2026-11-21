import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

struct MCPServerSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Binding var isEnabled: Bool
    @Binding var port: Int
    @Binding var storedExposedTools: String

    @State private var portDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Server")
                        .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    Text("Expose selected RxCode tools to other local MCP clients.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack {
                Text("Enable MCP Server")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                Spacer(minLength: 12)
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .disabled(!appState.memoryEnabled)

            if !appState.memoryEnabled {
                Label("Enable Memory to start the MCP server.", systemImage: "pause.circle")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Tools to Expose")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

                ForEach(MCPServerTool.allCases) { tool in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title)
                                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                            Text(tool.summary)
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: binding(for: tool))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Port")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.secondary)
                    TextField("Port", text: $portDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { applyPort() }
                    Button("Apply") { applyPort() }
                        .disabled(parsedPort == nil || parsedPort == port)
                    Spacer()
                }

                if let endpoint = IDEMCPServer.memoryAPIEndpoint(port: port) {
                    LabeledContent("Transport") {
                        Text("Streamable HTTP")
                    }
                    .font(.system(size: ClaudeTheme.size(11)))

                    LabeledContent("Endpoint") {
                        HStack(spacing: 8) {
                            Text(verbatim: endpoint.absoluteString)
                                .textSelection(.enabled)
                            Button {
                                copyEndpoint(endpoint)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                    }
                    .font(.system(size: ClaudeTheme.size(11)))
                }

                serverStatus

                Text("Keep RxCode running while another MCP client uses this server. Ports 19847–19946 are reserved for chat sessions.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { portDraft = String(port) }
        .onChange(of: port) { _, newValue in
            portDraft = String(newValue)
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        if let error = appState.memoryMCPServerError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ClaudeTheme.statusError)
        } else if appState.memoryMCPServerRunning {
            Label("Running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusSuccess)
        } else {
            Label("Server stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private var parsedPort: Int? {
        guard let value = Int(portDraft), IDEMCPServer.isValidMemoryAPIPort(value) else { return nil }
        return value
    }

    private func binding(for tool: MCPServerTool) -> Binding<Bool> {
        Binding(
            get: { IDEMCPServer.exposedTools(from: storedExposedTools).contains(tool) },
            set: { isSelected in
                var tools = IDEMCPServer.exposedTools(from: storedExposedTools)
                if isSelected {
                    tools.insert(tool)
                } else {
                    tools.remove(tool)
                }
                storedExposedTools = IDEMCPServer.storedValue(for: tools)
            }
        )
    }

    private func applyPort() {
        guard let parsedPort else { return }
        port = parsedPort
    }

    private func copyEndpoint(_ endpoint: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.absoluteString, forType: .string)
    }
}
