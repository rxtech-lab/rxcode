import SwiftUI
import RxCodeCore

/// Image-only controls: a simple quality preset and aspect in the menu,
/// everything else in a dedicated sheet with a cancellable draft.
struct ImageQualityPicker: View {
    @AppStorage(ImageGenerationSettings.storageKey) private var saved = ""
    @State private var showingAdvanced = false
    @State private var draft = ImageGenerationSettings()

    private var settings: ImageGenerationSettings { .decode(saved) }

    var body: some View {
        Menu {
            Picker(String(localized: "Quality", bundle: .module), selection: Binding(get: { settings.quality }, set: { quality in
                if quality == .custom {
                    draft = settings
                    draft.select(.custom)
                    showingAdvanced = true
                } else {
                    var updated = settings
                    updated.select(quality)
                    saved = updated.encoded
                }
            })) {
                ForEach(ImageGenerationSettings.Quality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Picker(String(localized: "Aspect Ratio", bundle: .module), selection: Binding(get: { settings.aspect }, set: { aspect in
                var updated = settings
                updated.select(aspect)
                saved = updated.encoded
            })) {
                ForEach(ImageGenerationSettings.Aspect.allCases, id: \.self) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            Divider()
            Button(String(localized: "Advanced Settings…", bundle: .module)) {
                draft = settings
                showingAdvanced = true
            }
        } label: {
            Label("\(settings.quality.title) · \(settings.aspect.title)", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Image quality, aspect ratio and advanced settings", bundle: .module))
        .accessibilityIdentifier("image-quality-picker")
        .sheet(isPresented: $showingAdvanced) {
            ImageQualitySettingsSheet(settings: draft) { saved = $0.encoded }
        }
    }
}

private struct ImageQualitySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: ImageGenerationSettings
    let save: (ImageGenerationSettings) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Quality", bundle: .module)) {
                    Picker(String(localized: "Preset", bundle: .module), selection: Binding(get: { settings.quality }, set: { settings.select($0) })) {
                        ForEach(ImageGenerationSettings.Quality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Picker(String(localized: "Aspect Ratio", bundle: .module), selection: Binding(get: { settings.aspect }, set: { settings.select($0) })) {
                        ForEach(ImageGenerationSettings.Aspect.allCases, id: \.self) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                    Text("Presets scale the resolution and the sampling steps the model recommends. Higher presets use more memory and time.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(String(localized: "Advanced", bundle: .module)) {
                    Stepper(value: custom(\.width), in: 256...2048, step: 64) {
                        Text("Width: \(settings.width) px", bundle: .module)
                    }
                    Stepper(value: custom(\.height), in: 256...2048, step: 64) {
                        Text("Height: \(settings.height) px", bundle: .module)
                    }
                    Stepper(value: custom(\.steps), in: 0...150) {
                        Text(settings.steps == 0
                             ? String(localized: "Sampling steps: model default", bundle: .module)
                             : String(localized: "Sampling steps: \(settings.steps)", bundle: .module))
                    }
                    Toggle(String(localized: "Override guidance (CFG)", bundle: .module), isOn: Binding(
                        get: { settings.cfgScale != nil },
                        set: { settings.cfgScale = $0 ? (settings.cfgScale ?? 7) : nil; settings.quality = .custom }
                    ))
                    if let cfg = settings.cfgScale {
                        Slider(value: Binding(get: { cfg }, set: { settings.cfgScale = ($0 * 10).rounded() / 10; settings.quality = .custom }),
                               in: 0...20) {
                            Text("Guidance: \(cfg, format: .number.precision(.fractionLength(1)))", bundle: .module)
                        }
                    }
                    TextField(String(localized: "Seed (−1 for random)", bundle: .module), value: $settings.seed, format: .number)
                    TextField(String(localized: "Negative prompt", bundle: .module), text: $settings.negativePrompt, axis: .vertical)
                        .lineLimit(2...4)
                    Text("Width, height, steps and guidance apply when the preset is Custom. Distilled models usually want guidance 1.0.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(String(localized: "Refine", bundle: .module)) {
                    Slider(value: $settings.refineStrength, in: 0.05...1) {
                        Text("Change: \(Int(settings.refineStrength * 100))%", bundle: .module)
                    }
                    Text("How far a refine moves away from the source image. Lower keeps the composition; higher follows the new prompt more.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "Image Settings", bundle: .module))
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
        .frame(width: 540, height: 640)
    }

    private func custom(_ keyPath: WritableKeyPath<ImageGenerationSettings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] }, set: {
            settings[keyPath: keyPath] = $0
            settings.quality = .custom
        })
    }
}
