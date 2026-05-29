import RxCodeCore
import SwiftUI

struct MCPSetupPreview: View {
    @Binding var spec: MCPServerSpec
    @Binding var argsText: String
    @Binding var isSaving: Bool
    @Binding var added: Bool
    @Binding var errorMessage: String?
    let onSave: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("First MCP Server")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if added {
                    Label(LocalizedStringKey("Added"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                }
            }

            Text("Connect any MCP server to give every agent extra tools. You can also skip this and add servers later in Settings → MCP.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))

            field(label: LocalizedStringKey("Name"), placeholder: "my-server", text: $spec.name)

            HStack(spacing: 8) {
                Text("Transport")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 78, alignment: .leading)
                Picker("", selection: $spec.transport) {
                    ForEach(MCPTransport.allCases) { t in
                        Text(verbatim: t.displayNameText).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if spec.transport == .stdio {
                field(label: LocalizedStringKey("Command"), placeholder: "npx", text: $spec.command)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Args (one per line)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    TextEditor(text: $argsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 48, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                        .onChange(of: argsText) { _, newValue in
                            spec.args = newValue
                                .split(whereSeparator: \.isNewline)
                                .map { String($0).trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                }
            } else {
                field(label: LocalizedStringKey("URL"), placeholder: "https://example.com/mcp", text: $spec.url)
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button {
                    Task { await onSave() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(added ? LocalizedStringKey("Saved") : LocalizedStringKey("Save Server"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background((canSave ? ClaudeTheme.accent : ClaudeTheme.textTertiary).opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isSaving || added)
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
    }

    private var canSave: Bool {
        guard !spec.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch spec.transport {
        case .stdio:
            return !spec.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return URL(string: spec.url) != nil && !spec.url.isEmpty
        }
    }

    private func field(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 78, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
