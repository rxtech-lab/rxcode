import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Environments

extension RunProfileDetailForm {
    func pickXcodeContainer(onPick: @escaping (String, Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xcodeproj") ?? .package,
            UTType(filenameExtension: "xcworkspace") ?? .package,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name: String
        let root = (project.path as NSString).standardizingPath
        let std = (url.path as NSString).standardizingPath
        if std.hasPrefix(root + "/") {
            name = String(std.dropFirst(root.count + 1))
        } else {
            name = std
        }
        onPick(name, url.pathExtension == "xcworkspace")
    }

    var activePresetIndex: Int? {
        guard let id = profile.bash.activePresetId ?? profile.bash.environments.first?.id else { return nil }
        return profile.bash.environments.firstIndex { $0.id == id }
    }

    @ViewBuilder
    var environmentsSection: some View {
        Section {
            LabeledContent("Preset") {
                HStack {
                    Picker("", selection: Binding(
                        get: { profile.bash.activePresetId ?? profile.bash.environments.first?.id },
                        set: { profile.bash.activePresetId = $0 }
                    )) {
                        if profile.bash.environments.isEmpty {
                            Text("None").tag(UUID?.none)
                        } else {
                            ForEach(profile.bash.environments) { preset in
                                Text(preset.name.isEmpty ? "Untitled" : preset.name)
                                    .tag(UUID?.some(preset.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Button {
                        addPreset()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Preset")
                    Button {
                        deleteActivePreset()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(profile.bash.environments.isEmpty)
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
    func presetEditor(idx: Int) -> some View {
        let preset = Binding(
            get: { profile.bash.environments[idx] },
            set: { profile.bash.environments[idx] = $0 }
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

    func addPreset() {
        let preset = EnvironmentPreset(
            name: profile.bash.environments.isEmpty ? "dev" : "preset \(profile.bash.environments.count + 1)"
        )
        profile.bash.environments.append(preset)
        profile.bash.activePresetId = preset.id
    }

    func deleteActivePreset() {
        guard let idx = activePresetIndex else { return }
        let removed = profile.bash.environments.remove(at: idx)
        if profile.bash.activePresetId == removed.id {
            profile.bash.activePresetId = profile.bash.environments.first?.id
        }
    }

    @ViewBuilder
    func manualKVTable(preset: Binding<EnvironmentPreset>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row with column titles and add button
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
                // Variable rows
                ForEach(preset.wrappedValue.manualVars.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("Key", text: Binding(
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
}
