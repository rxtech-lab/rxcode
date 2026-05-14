import SwiftUI
import ClarcCore

struct MCPServerEditorSheet: View {
    /// Returns true on success (sheet dismisses), false on failure (stays open).
    let onSave: (MCPServerSpec, MCPScope) async -> Bool

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var spec = MCPServerSpec()
    @State private var scope: MCPScope = .user
    @State private var argsText: String = ""
    @State private var isSaving = false
    @State private var isProbing = false
    @State private var probe: MCPProbeResult?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    scopeField
                    transportField
                    Divider()
                    if spec.transport == .stdio {
                        stdioFields
                    } else {
                        httpFields
                    }
                    Divider()
                    testSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 640)
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            Text("Add MCP Server")
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await save() }
            } label: {
                if isSaving { ProgressView().controlSize(.small) }
                else { Text("Save") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("my-server", text: $spec.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var scopeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scope")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $scope) {
                ForEach(MCPScope.allCases) { s in
                    Text(LocalizedStringKey(s.displayName)).tag(s)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(LocalizedStringKey(scope.subtitle))
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
        }
    }

    private var transportField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transport")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $spec.transport) {
                ForEach(MCPTransport.allCases) { t in
                    Text(verbatim: t.displayName).tag(t)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("npx", text: $spec.command)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Args (one per line)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $argsText)
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                    .frame(minHeight: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                    .onChange(of: argsText) { _, newValue in
                        spec.args = newValue
                            .split(whereSeparator: \.isNewline)
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }
            keyValueEditor(
                title: "Environment",
                placeholder: ("KEY", "value"),
                items: $spec.env
            )
        }
    }

    private var httpFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("https://example.com/mcp", text: $spec.url)
                    .textFieldStyle(.roundedBorder)
            }
            keyValueEditor(
                title: "Headers",
                placeholder: ("Header-Name", "value"),
                items: $spec.headers
            )
        }
    }

    private func keyValueEditor(
        title: LocalizedStringKey,
        placeholder: (String, String),
        items: Binding<[MCPKeyValue]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    items.wrappedValue.append(MCPKeyValue())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: ClaudeTheme.size(10)))
                }
                .buttonStyle(.borderless)
            }
            ForEach(items.wrappedValue) { kv in
                HStack(spacing: 6) {
                    TextField(placeholder.0, text: bindingForKey(items: items, id: kv.id))
                        .textFieldStyle(.roundedBorder)
                    TextField(placeholder.1, text: bindingForValue(items: items, id: kv.id))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        items.wrappedValue.removeAll { $0.id == kv.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func bindingForKey(items: Binding<[MCPKeyValue]>, id: UUID) -> Binding<String> {
        Binding(
            get: { items.wrappedValue.first(where: { $0.id == id })?.key ?? "" },
            set: { newValue in
                if let idx = items.wrappedValue.firstIndex(where: { $0.id == id }) {
                    items.wrappedValue[idx].key = newValue
                }
            }
        )
    }

    private func bindingForValue(items: Binding<[MCPKeyValue]>, id: UUID) -> Binding<String> {
        Binding(
            get: { items.wrappedValue.first(where: { $0.id == id })?.value ?? "" },
            set: { newValue in
                if let idx = items.wrappedValue.firstIndex(where: { $0.id == id }) {
                    items.wrappedValue[idx].value = newValue
                }
            }
        )
    }

    // MARK: - Test section

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Test connection")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await runTest() }
                } label: {
                    if isProbing { ProgressView().controlSize(.small) }
                    else { Text("Test") }
                }
                .buttonStyle(.bordered)
                .disabled(isProbing || !canProbe)
            }

            if let probe {
                if probe.ok {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(verbatim: probeSuccessText(probe))
                            .font(.system(size: ClaudeTheme.size(11)))
                    }
                    if !probe.tools.isEmpty {
                        ForEach(probe.tools.prefix(8)) { tool in
                            Text(verbatim: "• \(tool.name)")
                                .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if probe.tools.count > 8 {
                            Text(verbatim: "+ \(probe.tools.count - 8) more")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(verbatim: probe.error ?? "Probe failed.")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func probeSuccessText(_ probe: MCPProbeResult) -> String {
        var parts: [String] = ["Connected"]
        if let name = probe.serverName { parts.append("(\(name))") }
        parts.append("— \(probe.tools.count) tools")
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    private func runTest() async {
        isProbing = true
        defer { isProbing = false }
        probe = await appState.mcp.probe(spec: spec)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await onSave(spec, scope)
        if ok { dismiss() }
    }

    // MARK: - Validation

    private var canSave: Bool {
        guard !spec.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch spec.transport {
        case .stdio:
            return !spec.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return URL(string: spec.url) != nil && !spec.url.isEmpty
        }
    }

    private var canProbe: Bool {
        switch spec.transport {
        case .stdio:
            return !spec.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return URL(string: spec.url) != nil && !spec.url.isEmpty
        }
    }
}
