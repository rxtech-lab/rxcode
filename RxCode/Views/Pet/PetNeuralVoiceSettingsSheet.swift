import Observation
import RxCodeCore
import SwiftUI

// MARK: - README-Derived Voice Presets

/// Voice choices for an installed neural TTS model. The setup agent reads the
/// model's README into a `StudioModelConfig` (shared with Audio Studio); when
/// that form names voices, they become the pet's voice picker. Kokoro keeps a
/// built-in list for models that haven't been analyzed yet.
@MainActor
enum PetVoicePresets {
    struct Option: Hashable, Identifiable {
        let id: String
        let label: String
    }

    static func config(for modelID: String) -> StudioModelConfig? {
        StudioModelConfig.load(modelID: modelID)
    }

    static func voiceParameter(in config: StudioModelConfig?) -> StudioParameter? {
        config?.parameters.first { $0.key == .voice }
    }

    /// The README's voice names, else Kokoro's built-in presets, else nil (free text).
    static func options(modelID: String, config: StudioModelConfig?) -> [Option]? {
        if let parameter = voiceParameter(in: config), let options = parameter.options, !options.isEmpty {
            return options.map { Option(id: $0.display, label: $0.display) }
        }
        if modelID.localizedCaseInsensitiveContains("kokoro") {
            return PetLocalSpeechSynthesizer.kokoroVoicePresets.map { Option(id: $0.id, label: $0.label) }
        }
        return nil
    }

    /// The README's default voice, else the first listed option.
    static func defaultVoice(modelID: String, config: StudioModelConfig?) -> String? {
        if let parameter = voiceParameter(in: config), let text = parameter.defaultValue.text, !text.isEmpty {
            return text
        }
        return options(modelID: modelID, config: config)?.first?.id
    }

    /// Activates `model`, moving the voice preset onto one the model lists.
    static func select(model: LocalModelInfo, in controller: PetController) {
        controller.configuration.localTTSModelID = model.id
        let config = config(for: model.id)
        guard let options = options(modelID: model.id, config: config),
              !options.contains(where: { $0.id == controller.configuration.localTTSVoicePreset }),
              let fallback = defaultVoice(modelID: model.id, config: config) else { return }
        controller.configuration.localTTSVoicePreset = fallback
    }
}

// MARK: - Neural Voice Settings Sheet

/// Per-model voice settings built from the model's README by the setup agent.
/// Edits a draft so cancelling leaves the active voice untouched.
struct PetNeuralVoiceSettingsSheet: View {
    @Bindable var controller: PetController
    let model: LocalModelInfo
    var onSaved: () -> Void = {}
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StudioModelConfig.storageKey) private var savedConfigs = ""
    @AppStorage(StudioModelConfig.pendingStorageKey) private var pendingConfigs = ""

    @State private var draftVoice = ""
    @State private var seedText = "42"
    @State private var isAnalyzing = false
    @State private var analyzeError: String?
    @State private var preview = PetVoiceDraftPreview()

    private var config: StudioModelConfig? { StudioModelConfig.decodeAll(savedConfigs)[model.id] }
    private var isSettingUpInBackground: Bool {
        config == nil && StudioModelConfig.decodePending(pendingConfigs).contains(model.id)
    }

    private var voiceParameter: StudioParameter? { PetVoicePresets.voiceParameter(in: config) }
    private var voiceOptions: [PetVoicePresets.Option]? { PetVoicePresets.options(modelID: model.id, config: config) }
    private var isQwenBase: Bool {
        model.id.localizedCaseInsensitiveContains("qwen3-tts") && model.id.localizedCaseInsensitiveContains("-base")
    }

    private var fixedSeed: Int? {
        guard let value = Int(seedText), (0...Int(Int32.max)).contains(value) else { return nil }
        return value
    }

    /// README settings the pet's speech engine doesn't apply; shown for reference.
    private var otherParameters: [StudioParameter] {
        (config?.parameters ?? []).filter { $0.key != .voice && $0.key != .seed }
    }

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                readmeSection
                voiceSection
                seedSection
                if !otherParameters.isEmpty {
                    Section {
                        ForEach(otherParameters) { parameter in
                            LabeledContent(parameter.label, value: parameter.defaultValue.display)
                        }
                    } header: {
                        Text("Other README Settings")
                    } footer: {
                        Text("These apply in Audio Studio. Pet speech uses the voice and seed above.")
                    }
                }
                Section("Preview") {
                    Button {
                        if preview.isPlaying {
                            preview.stop()
                        } else if let seed = fixedSeed {
                            var draft = controller.configuration
                            draft.localTTSModelID = model.id
                            draft.localTTSVoicePreset = draftVoice
                            draft.localTTSSeed = seed
                            preview.play(configuration: draft, controller: controller)
                        }
                    } label: {
                        Label(preview.isPlaying ? "Stop Preview" : "Preview Voice",
                              systemImage: preview.isPlaying ? "stop.circle" : "play.circle")
                    }
                    .disabled(!preview.isPlaying && fixedSeed == nil)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Voice Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Voice & Save") {
                        guard let seed = fixedSeed else { return }
                        controller.configuration.localTTSModelID = model.id
                        controller.configuration.localTTSVoicePreset = draftVoice
                        controller.configuration.localTTSSeed = seed
                        onSaved()
                        dismiss()
                    }
                    .disabled(fixedSeed == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 600, maxWidth: .infinity,
               minHeight: 560, idealHeight: 660, maxHeight: .infinity)
        .overlay {
            if isAnalyzing {
                PetActionStatusOverlay(message: "Reading \(model.displayName)'s README…")
            } else if preview.isPlaying {
                PetActionStatusOverlay(message: preview.status ?? "Previewing voice…")
            }
        }
        .alert("Couldn't Build Voice Settings", isPresented: Binding(
            get: { analyzeError != nil },
            set: { if !$0 { analyzeError = nil } }
        )) {
            Button("OK", role: .cancel) { analyzeError = nil }
        } message: {
            Text(analyzeError ?? "")
        }
        .alert("Voice Preview Failed", isPresented: Binding(
            get: { preview.errorMessage != nil },
            set: { if !$0 { preview.errorMessage = nil } }
        )) {
            Button("OK") { preview.errorMessage = nil }
        } message: {
            Text(preview.errorMessage ?? "")
        }
        .onChange(of: draftVoice) { preview.stop() }
        .onChange(of: seedText) { preview.stop() }
        .onChange(of: savedConfigs) { adoptDefaultVoiceIfNeeded() }
        .onDisappear { preview.shutdown() }
        .onAppear {
            let isActive = controller.configuration.localTTSModelID == model.id
            draftVoice = isActive ? controller.configuration.localTTSVoicePreset : ""
            seedText = String(controller.configuration.resolvedLocalTTSSeed)
            adoptDefaultVoiceIfNeeded()
        }
    }

    // MARK: - Sections

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Name", value: model.displayName)
            LabeledContent("Repository", value: model.repoID)
            LabeledContent("Format", value: model.format.label)
            LabeledContent("Size") {
                HStack(spacing: 8) {
                    Text(LocalModelFormat.bytes(model.sizeBytes))
                    LocalModelFitBadge(fit: appState.localModels.fit(bytes: model.sizeBytes))
                }
            }
        }
    }

    @ViewBuilder
    private var readmeSection: some View {
        Section {
            if isSettingUpInBackground {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The setup agent is reading this model's README…")
                        .foregroundStyle(.secondary)
                }
            } else if let config {
                if let summary = config.summary, !summary.isEmpty {
                    Text(summary)
                }
                if let generatedBy = config.generatedBy {
                    LabeledContent("Analyzed By", value: generatedBy)
                }
                LabeledContent("Analyzed", value: config.generatedAt.formatted(date: .abbreviated, time: .shortened))
                Button("Regenerate from README") { analyze() }
                    .disabled(isAnalyzing)
            } else {
                Text("The setup agent can read this model's README and build dedicated settings, such as the speaker names the model supports.")
                    .foregroundStyle(.secondary)
                Button("Analyze README") { analyze() }
                    .disabled(isAnalyzing)
            }
        } header: {
            Text("Settings from README")
        } footer: {
            Text("Uses the Audio Studio setup agent. Settings are shared with Audio Studio.")
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            if let voiceOptions {
                Picker(voiceParameter?.label ?? "Voice", selection: $draftVoice) {
                    if !draftVoice.isEmpty, !voiceOptions.contains(where: { $0.id == draftVoice }) {
                        Text("\(draftVoice) (Not Listed)").tag(draftVoice)
                    }
                    ForEach(voiceOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            } else if voiceParameter != nil {
                TextField(voiceParameter?.label ?? "Voice", text: $draftVoice, prompt: Text("Model Default"))
            } else if isQwenBase {
                LabeledContent("Voice", value: "Model Default")
            } else {
                TextField("Voice", text: $draftVoice, prompt: Text("Model Default"))
            }
        } header: {
            Text("Voice")
        } footer: {
            if let help = voiceParameter?.help, !help.isEmpty {
                Text(help)
            } else if config == nil, voiceOptions != nil {
                Text("Built-in Kokoro voices. Analyze the README to load every voice this model lists.")
            } else if isQwenBase {
                Text("Qwen3 Base generates speech without a preset speaker.")
            } else if config == nil {
                Text("Analyze the README to find the speaker names this model supports.")
            }
        }
    }

    private var seedSection: some View {
        Section {
            TextField("Voice Seed", text: $seedText)
            Button("Try Another Seed") {
                seedText = String(Int.random(in: 0...Int(Int32.max)))
            }
            if fixedSeed == nil {
                Text("Enter a whole number from 0 to 2147483647.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Variation")
        } footer: {
            Text("The seed controls sampling variation. Reusing it with the same model, voice, and text helps repeat a result.")
        }
    }

    // MARK: - Actions

    private func analyze() {
        isAnalyzing = true
        let previous = config
        Task {
            defer { isAnalyzing = false }
            do {
                let generated = try await appState.generateStudioConfig(modelID: model.id, previous: previous)
                StudioModelConfig.save(generated)
            } catch is CancellationError {
                return
            } catch {
                analyzeError = error.localizedDescription
            }
        }
    }

    /// Moves an empty or unlisted draft onto the README's default voice.
    private func adoptDefaultVoiceIfNeeded() {
        guard let options = voiceOptions,
              draftVoice.isEmpty || !options.contains(where: { $0.id == draftVoice }),
              let fallback = PetVoicePresets.defaultVoice(modelID: model.id, config: config) else { return }
        draftVoice = fallback
    }
}

// MARK: - Draft Preview

/// Owns draft playback independently of the saved voice configuration.
@MainActor
@Observable
final class PetVoiceDraftPreview {
    var isPlaying = false
    var status: String?
    var errorMessage: String?
    private var configuration = PetConfiguration()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    private let speaker = PetStandaloneSpeaker()
    @ObservationIgnored private lazy var synthesizer: PetLocalSpeechSynthesizer = {
        PetLocalSpeechSynthesizer { @MainActor [weak self] in
            let cfg = self?.configuration ?? PetConfiguration()
            return PetLocalSpeechSynthesizer.Configuration(
                modelID: cfg.localTTSModelID,
                voicePreset: cfg.localTTSVoicePreset,
                systemVoiceIdentifier: cfg.systemVoiceIdentifier,
                localeIdentifier: cfg.speechLocaleIdentifier,
                speechRate: cfg.speechRate,
                seed: cfg.resolvedLocalTTSSeed
            )
        }
    }()

    func play(configuration: PetConfiguration, controller: PetController) {
        stop()
        guard !controller.isMuted else {
            errorMessage = "Unmute the pet to preview a voice."
            return
        }
        controller.voiceDraftPreview = self
        self.configuration = configuration
        speaker.speechPlayback = controller.speechPlayback
        speaker.outputDeviceUID = { [weak self] in self?.configuration.speakerDeviceUID }
        errorMessage = nil
        isPlaying = true
        status = "Preparing voice preview…"
        speaker.onSpeakingStateChanged = { [weak self] speaking, _ in
            self?.isPlaying = speaking
            self?.status = speaking ? "Previewing voice…" : nil
        }
        speaker.onFailure = { [weak self] message in
            self?.errorMessage = message
            self?.isPlaying = false
            self?.status = nil
        }
        startTask = Task {
            await controller.stopVoice(drainAnnouncements: false)
            guard !Task.isCancelled, !controller.isMuted else { return }
            controller.standaloneSpeaker.stop()
            speaker.speak(text: "Hi there! I am RxBuddy, your RxCode voice companion.", synthesizer: synthesizer)
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        speaker.stop()
        isPlaying = false
        status = nil
    }

    func shutdown() {
        stop()
        speaker.teardown()
        let synthesizer = synthesizer
        Task { await synthesizer.shutdown() }
    }
}
