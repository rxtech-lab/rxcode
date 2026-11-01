import SwiftUI
import RxCodeCore

/// Audio-only controls: a simple delivery preset in the menu, voice,
/// language, length, seed and the transcription instruction in a dedicated
/// sheet with a cancellable draft.
struct AudioSettingsPicker: View {
    @AppStorage(AudioGenerationSettings.storageKey) private var saved = ""
    @State private var showingAdvanced = false
    @State private var draft = AudioGenerationSettings()

    private var settings: AudioGenerationSettings { .decode(saved) }

    var body: some View {
        Menu {
            Picker(String(localized: "Delivery", bundle: .module), selection: Binding(get: { settings.delivery }, set: { delivery in
                if delivery == .custom {
                    draft = settings
                    draft.select(.custom)
                    showingAdvanced = true
                } else {
                    var updated = settings
                    updated.select(delivery)
                    saved = updated.encoded
                }
            })) {
                ForEach(AudioGenerationSettings.Delivery.allCases, id: \.self) { delivery in
                    Text(delivery.title).tag(delivery)
                }
            }
            Divider()
            Button(String(localized: "Advanced Settings…", bundle: .module)) {
                draft = settings
                showingAdvanced = true
            }
        } label: {
            Label(settings.delivery.title, systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Audio delivery and advanced settings", bundle: .module))
        .accessibilityIdentifier("audio-settings-picker")
        .sheet(isPresented: $showingAdvanced) {
            AudioSettingsSheet(settings: draft) { saved = $0.encoded }
        }
    }
}

private struct AudioSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: AudioGenerationSettings
    let save: (AudioGenerationSettings) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Speech", bundle: .module)) {
                    Picker(String(localized: "Delivery", bundle: .module), selection: Binding(get: { settings.delivery }, set: { settings.select($0) })) {
                        ForEach(AudioGenerationSettings.Delivery.allCases, id: \.self) { delivery in
                            Text(delivery.title).tag(delivery)
                        }
                    }
                    Slider(value: Binding(get: { settings.temperature }, set: {
                        settings.temperature = ($0 * 100).rounded() / 100
                        settings.delivery = .custom
                    }), in: 0...1.5) {
                        Text("Variation: \(settings.temperature, format: .number.precision(.fractionLength(2)))", bundle: .module)
                    }
                    TextField(String(localized: "Voice (model default when empty)", bundle: .module), text: $settings.voice)
                    TextField(String(localized: "Seed (−1 for random)", bundle: .module), value: $settings.seed, format: .number)
                    Text("Steady reads repeat well; expressive reads vary pitch and pacing. A fixed seed makes a take reproducible, which helps when refining wording.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(String(localized: "Language and Length", bundle: .module)) {
                    TextField(String(localized: "Language code, e.g. en (automatic when empty)", bundle: .module), text: $settings.language)
                    Stepper(value: $settings.maxTokens, in: 256...32_768, step: 256) {
                        Text("Maximum length: \(settings.maxTokens) tokens", bundle: .module)
                    }
                }
                Section(String(localized: "Transcription", bundle: .module)) {
                    TextField(String(localized: "Instruction", bundle: .module), text: $settings.transcriptionInstruction, axis: .vertical)
                        .lineLimit(2...4)
                    Text("Used when an attached audio file is sent without a message. A message replaces it, for example “Summarize this recording.”", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "Audio Settings", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) { save(settings.validated); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 540, height: 600)
    }
}

/// Decision-only control: whether to search the web first, and how many
/// results the model reads.
struct DecisionSettingsPicker: View {
    @AppStorage(DecisionSettings.storageKey) private var saved = ""

    private var settings: DecisionSettings { .decode(saved) }

    var body: some View {
        Menu {
            Toggle(String(localized: "Search the Web", bundle: .module), isOn: Binding(get: { settings.searchWeb }, set: {
                var updated = settings
                updated.searchWeb = $0
                saved = updated.encoded
            }))
            Picker(String(localized: "Web Results", bundle: .module), selection: Binding(get: { settings.maxSources }, set: {
                var updated = settings
                updated.maxSources = $0
                saved = updated.encoded
            })) {
                ForEach([3, 5, 8, 10], id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .disabled(!settings.searchWeb)
        } label: {
            Label(settings.searchWeb ? String(localized: "Web", bundle: .module) : String(localized: "Offline", bundle: .module),
                  systemImage: settings.searchWeb ? "globe" : "network.slash")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Search the web for context before deciding", bundle: .module))
        .accessibilityIdentifier("decision-settings-picker")
    }
}
