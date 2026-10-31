import RxCodeCore
import SwiftUI

/// The RxCode Agent entry in Settings → Agent. Always shown: it is the one
/// agent that needs nothing installed outside RxCode.
struct LocalAgentSettingsRow: View {
    @Environment(AppState.self) private var appState
    @State private var showModels = false

    private var store: LocalModelStore { appState.localModels }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: ClaudeTheme.size(16)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 24, height: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("RxCode Agent")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text("Local")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                    LocalServerStatusBadge(status: store.serverStatus)
                    Spacer(minLength: 0)
                }
                Text("Runs open-weight models from Hugging Face on this Mac, with opencode-style tools.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(summary)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
            }
            Button("Manage Models…") { showModels = true }
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1),
        )
        .sheet(isPresented: $showModels) {
            LocalModelsSheet()
                .frame(minWidth: 760, idealWidth: 820, minHeight: 640, idealHeight: 720)
        }
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(store.runtime.map { "llama.cpp \($0.version)" } ?? "llama.cpp not installed")
        if let mlx = store.mlxRuntime { parts.append("MLX \(mlx.version)") }
        parts.append(store.installed.isEmpty
            ? "No models downloaded"
            : "\(store.installed.count) model\(store.installed.count == 1 ? "" : "s") downloaded")
        return parts.joined(separator: " · ")
    }
}

struct LocalServerStatusBadge: View {
    let status: LlamaServerStatus

    var body: some View {
        switch status {
        case .running:
            badge("Loaded", color: ClaudeTheme.statusSuccess)
        case .loading:
            badge("Loading…", color: ClaudeTheme.statusWarning)
        case .failed:
            badge("Failed", color: ClaudeTheme.statusError)
        case .stopped:
            EmptyView()
        }
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .foregroundStyle(color)
    }
}
