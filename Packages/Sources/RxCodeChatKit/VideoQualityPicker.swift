import SwiftUI
import RxCodeCore

/// Video-only controls; editing happens in a dedicated sheet with a cancellable draft.
struct VideoQualityPicker: View {
    @AppStorage(VideoGenerationSettings.storageKey) private var saved = ""
    @State private var showingAdvanced = false
    @State private var draft = VideoGenerationSettings()

    private var settings: VideoGenerationSettings { .decode(saved) }

    var body: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { settings.quality }, set: { quality in
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
                ForEach(VideoGenerationSettings.Quality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Divider()
            Button("Advanced Settings…") {
                draft = settings
                showingAdvanced = true
            }
        } label: {
            Label(settings.quality.title, systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Video quality and advanced settings")
        .accessibilityIdentifier("video-quality-picker")
        .sheet(isPresented: $showingAdvanced) {
            VideoQualitySettingsSheet(settings: draft) { saved = $0.encoded }
        }
    }
}

private struct VideoQualitySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: VideoGenerationSettings
    let save: (VideoGenerationSettings) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Quality") {
                    Picker("Preset", selection: Binding(get: { settings.quality }, set: { settings.select($0) })) {
                        ForEach(VideoGenerationSettings.Quality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Text("Higher presets increase resolution and sampling work, using more memory and time. Results depend on the model; these presets do not add an upscaling pass.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Advanced") {
                    Stepper("Width: \(settings.width) px", value: custom(\.width), in: 256...1920, step: 32)
                    Stepper("Height: \(settings.height) px", value: custom(\.height), in: 256...1920, step: 32)
                    Stepper("Sampling steps: \(settings.steps)", value: custom(\.steps), in: 1...100)
                    Stepper("Frames: \(settings.frames)", value: custom(\.frames), in: 9...241, step: 8)
                    Stepper("Frame rate: \(settings.fps) fps", value: custom(\.fps), in: 1...60)
                    TextField("Seed (−1 for random)", value: custom(\.seed), format: .number)
                    Text("H3 guidance is fixed at 1.0. A fixed seed helps compare settings. Quality settings apply to future local video generations across windows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Video Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(settings.validated); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 540, height: 540)
    }

    private func custom(_ keyPath: WritableKeyPath<VideoGenerationSettings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] }, set: {
            settings[keyPath: keyPath] = $0
            settings.quality = .custom
        })
    }
}
