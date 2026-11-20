import SwiftUI

struct PetFlowcyVoiceSheet: View {
    @Bindable var controller: PetController
    let client: FlowcyMediaClient
    let isSignedIn: Bool
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var models: [FlowcyMediaModel] = []
    @State private var modelID: String?
    @State private var voices: [FlowcySpeechVoice] = []
    @State private var loadedModelID: String?
    @State private var voiceID: String?
    @State private var search = ""
    @State private var reload = 0
    @State private var loadingModels = true
    @State private var loadError: String?
    @State private var preview = PetVoiceDraftPreview()

    private var model: FlowcyMediaModel? { models.first { $0.id == modelID } }

    private var selection: FlowcySpeechSelection? {
        guard isSignedIn, !loadingModels, loadError == nil,
              let model, model.id == loadedModelID, let voiceID else { return nil }
        if let voice = voices.first(where: { $0.id == voiceID }) {
            return FlowcySpeechSelection(model: model, voice: voice)
        }
        let id = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.speechProvider == .gateway, !id.isEmpty, id.utf16.count <= 160 else { return nil }
        return FlowcySpeechSelection(model: model, voice: FlowcySpeechVoice(id: id, name: id))
    }

    private var filteredVoices: [FlowcySpeechVoice] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return voices }
        return voices.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
                || $0.languageName?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSignedIn {
                    catalog
                        .task(id: reload) { await loadModels() }
                        .task(id: modelID) { await loadVoices() }
                } else {
                    ContentUnavailableView("Sign In to Flowcy", systemImage: "person.crop.circle",
                                           description: Text("Sign in to your account in Settings → Flowcy to choose a speech voice."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Flowcy Speech Voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem {
                    Button(preview.isPlaying ? "Stop Preview" : "Preview Voice") {
                        if preview.isPlaying {
                            preview.stop()
                        } else if let selection {
                            var draft = controller.configuration
                            draft.flowcyVoice = selection
                            preview.play(configuration: draft, controller: controller, flowcyClient: client)
                        }
                    }
                    .disabled(controller.isMuted || selection == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Voice") {
                        guard let selection else { return }
                        controller.configuration.flowcyVoice = selection
                        onSaved()
                        dismiss()
                    }
                    .disabled(selection == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 620, maxWidth: .infinity,
               minHeight: 540, idealHeight: 640, maxHeight: .infinity)
        .overlay {
            if preview.isPlaying {
                PetActionStatusOverlay(message: preview.status ?? "Previewing voice…").allowsHitTesting(false)
            }
        }
        .onChange(of: voiceID) { preview.stop() }
        .onDisappear { preview.shutdown() }
        .alert("Voice Preview Failed", isPresented: Binding(
            get: { preview.errorMessage != nil }, set: { if !$0 { preview.errorMessage = nil } }
        )) {
            Button("OK") { preview.errorMessage = nil }
        } message: { Text(preview.errorMessage ?? "") }
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            if !models.isEmpty {
                Picker("Speech Model", selection: $modelID) {
                    ForEach(models) { Text($0.alias).tag(Optional($0.id)) }
                }
                .disabled(loadingModels)
                .padding()
                Divider()
            }
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't Load Flowcy Voices", systemImage: "exclamationmark.triangle")
                    } description: { Text(loadError) } actions: { Button("Retry") { reload += 1 } }
                } else if loadingModels || (modelID != nil && loadedModelID != modelID) {
                    ProgressView("Loading Flowcy voices…")
                } else if models.isEmpty {
                    ContentUnavailableView {
                        Label("No Speech Models", systemImage: "waveform")
                    } description: {
                        Text("Your Flowcy account has no enabled speech models.")
                    } actions: { Button("Refresh") { reload += 1 } }
                } else {
                    voiceList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var voiceList: some View {
        VStack(spacing: 0) {
            if model?.speechProvider == .gateway {
                TextField("Voice ID", text: Binding(get: { voiceID ?? "" }, set: { voiceID = $0 }),
                          prompt: Text("Enter a provider voice ID"))
                    .textFieldStyle(.roundedBorder)
                    .padding()
            }
            if voices.isEmpty {
                if model?.speechProvider == .gateway {
                    Spacer()
                } else {
                    ContentUnavailableView("No Voices Available", systemImage: "waveform")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(filteredVoices, selection: $voiceID) { voice in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                            if voice.locale != nil { Text(voice.id).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let language = voice.languageName { Text(language).foregroundStyle(.secondary) }
                    }
                    .tag(voice.id)
                    .help(voice.id)
                }
                .searchable(text: $search, prompt: "Search voices or languages")
                .overlay {
                    if filteredVoices.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Text("Previews and speech use your Flowcy account allowance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func loadModels() async {
        let previousID = modelID ?? controller.configuration.flowcyVoice?.model.id
        loadingModels = true
        loadError = nil
        do {
            let catalog = try await client.allModels(capability: "speech")
            try Task.checkCancellation()
            models = catalog.filter { $0.labels.contains("audio") }
            let nextID = models.first { $0.id == previousID }?.id ?? models.first?.id
            if nextID != nil && nextID == modelID {
                await loadVoices()
            } else {
                modelID = nextID
            }
        } catch {
            guard !Task.isCancelled else { return }
            models = []
            modelID = nil
            loadError = error.localizedDescription
        }
        loadingModels = false
    }

    private func loadVoices() async {
        preview.stop()
        loadedModelID = nil
        voices = []
        search = ""
        voiceID = nil
        guard let model else { return }
        loadError = nil
        do {
            let options = try await client.speechVoices(for: model)
            try Task.checkCancellation()
            guard model.id == modelID else { return }
            voices = options
            let saved = controller.configuration.flowcyVoice
            if let saved, saved.model.id == model.id,
               model.speechProvider == .gateway || options.contains(where: { $0.id == saved.voice.id }) {
                voiceID = saved.voice.id
            } else {
                voiceID = options.first?.id
            }
            loadedModelID = model.id
        } catch {
            guard !Task.isCancelled, model.id == modelID else { return }
            loadError = error.localizedDescription
        }
    }
}
