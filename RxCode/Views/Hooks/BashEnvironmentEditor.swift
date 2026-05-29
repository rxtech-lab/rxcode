import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Reusable environment-preset editor bound to a `BashRunConfig`. Extracted so
/// both the run-profile form and the hook form can share preset management,
/// `.env` loading, and the manual key/value table.
struct BashEnvironmentEditor: View {
    @Binding var bash: BashRunConfig
    let projectPath: String

    private var activePresetIndex: Int? {
        guard let id = bash.activePresetId ?? bash.environments.first?.id else { return nil }
        return bash.environments.firstIndex { $0.id == id }
    }

    var body: some View {
        Section {
            LabeledContent("Preset") {
                HStack {
                    Picker("", selection: Binding(
                        get: { bash.activePresetId ?? bash.environments.first?.id },
                        set: { bash.activePresetId = $0 }
                    )) {
                        if bash.environments.isEmpty {
                            Text("None").tag(UUID?.none)
                        } else {
                            ForEach(bash.environments) { preset in
                                Text(preset.name.isEmpty ? "Untitled" : preset.name)
                                    .tag(UUID?.some(preset.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Button { addPreset() } label: { Image(systemName: "plus") }
                        .help("Add Preset")
                    Button { deleteActivePreset() } label: { Image(systemName: "minus") }
                        .disabled(bash.environments.isEmpty)
                        .help("Delete Preset")
                }
            }
            if let idx = activePresetIndex {
                presetEditor(idx: idx)
            }
        } header: {
            Text("Environments")
        } footer: {
            if activePresetIndex == nil {
                Text("Add a preset (e.g. \"dev\", \"prod\") to configure environment variables.")
            }
        }
    }

    @ViewBuilder
    private func presetEditor(idx: Int) -> some View {
        let preset = Binding(
            get: { bash.environments[idx] },
            set: { bash.environments[idx] = $0 }
        )

        TextField("Preset Name", text: preset.name, prompt: Text("dev / prod / beta"))

        Toggle("Load from .env file", isOn: preset.loadFromFile)

        if preset.wrappedValue.loadFromFile {
            LabeledContent("Env File") {
                HStack {
                    TextField(".env", text: Binding(
                        get: { preset.wrappedValue.envFilePath ?? "" },
                        set: { preset.wrappedValue.envFilePath = $0 }
                    ))
                    Button("Browse…") {
                        pickFile { picked in
                            preset.wrappedValue.envFilePath = picked
                        }
                    }
                }
            }
        }

        Toggle("Manual key/value pairs", isOn: preset.useManualKV)

        if preset.wrappedValue.useManualKV {
            manualKVTable(preset: preset)
        }
    }

    private func addPreset() {
        let preset = EnvironmentPreset(
            name: bash.environments.isEmpty ? "dev" : "preset \(bash.environments.count + 1)"
        )
        bash.environments.append(preset)
        bash.activePresetId = preset.id
    }

    private func deleteActivePreset() {
        guard let idx = activePresetIndex else { return }
        let removed = bash.environments.remove(at: idx)
        if bash.activePresetId == removed.id {
            bash.activePresetId = bash.environments.first?.id
        }
    }

    @ViewBuilder
    private func manualKVTable(preset: Binding<EnvironmentPreset>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
                Text("Value")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    preset.wrappedValue.manualVars.append(EnvVar())
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Add Variable")
            }

            if preset.wrappedValue.manualVars.isEmpty {
                HStack {
                    Spacer()
                    Text("No environment variables defined")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                ForEach(preset.wrappedValue.manualVars.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("API_KEY", text: Binding(
                            get: { preset.wrappedValue.manualVars[i].key },
                            set: { preset.wrappedValue.manualVars[i].key = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140)

                        TextField("value", text: Binding(
                            get: { preset.wrappedValue.manualVars[i].value },
                            set: { preset.wrappedValue.manualVars[i].value = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            preset.wrappedValue.manualVars.remove(at: i)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove Variable")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - File picker

    private func pickFile(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: projectPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(relativePath(for: url))
    }

    /// Convert an absolute URL to a project-relative path when inside the root.
    private func relativePath(for url: URL) -> String {
        let root = (projectPath as NSString).standardizingPath
        let std = (url.path as NSString).standardizingPath
        if std.hasPrefix(root + "/") {
            return String(std.dropFirst(root.count + 1))
        }
        return std
    }
}
