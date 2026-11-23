import SwiftUI
import RxCodeCore

@MainActor @Observable
final class CodingPlanRadioPlayer {
    private(set) var listening = false
    var error: String?
    private let speaker = PetStandaloneSpeaker()
    private var synthesizer: PetLocalSpeechSynthesizer?
    private var next: String?

    func start(configuration: PetLocalSpeechSynthesizer.Configuration) {
        stop()
        synthesizer = PetLocalSpeechSynthesizer { configuration }
        listening = true
        speaker.onFailure = { [weak self] message in
            self?.stop()
            self?.error = message
        }
        speaker.onSpeakingStateChanged = { [weak self] speaking, _ in
            guard !speaking, let self, let next = self.next else { return }
            self.next = nil
            self.receive(next)
        }
    }

    func receive(_ text: String) {
        guard listening, let synthesizer else { return }
        if speaker.isSpeaking {
            // Keep the listener near the live discussion when synthesis falls behind.
            next = text
        } else {
            speaker.speak(text: text, synthesizer: synthesizer)
        }
    }

    func stop() {
        listening = false
        next = nil
        speaker.onSpeakingStateChanged = nil
        speaker.onFailure = nil
        speaker.teardown()
        if let synthesizer { Task { await synthesizer.shutdown() } }
        synthesizer = nil
    }
}

struct CodingPlanRadioControl: View {
    @Environment(AppState.self) private var appState
    let room: CodingPlanRoom
    /// Owned by the workspace so playback survives this control leaving the screen.
    let player: CodingPlanRadioPlayer
    @State private var choosingVoice = false
    @AppStorage("codingPlanRadioLocalModel") private var localID = PetConfiguration.systemTTSModelID
    @AppStorage("codingPlanRadioFlowcyVoice") private var flowcyData = Data()

    private var flowcy: FlowcySpeechSelection? {
        try? JSONDecoder().decode(FlowcySpeechSelection.self, from: flowcyData)
    }
    private var localModels: [LocalModelInfo] {
        appState.localModels.installed.filter { LocalAudioMode(model: $0) == .speech }
    }
    private var client: FlowcyMediaClient { FlowcyMediaClient(auth: appState.rxAuth) }

    var body: some View {
        Menu {
            Button(player.listening ? "Stop Listening" : "Listen Live") {
                if player.listening { player.stop() } else { listen() }
            }
            Section("Local voice") {
                localChoice("macOS System Voice", id: PetConfiguration.systemTTSModelID)
                ForEach(localModels) { model in localChoice(model.displayName, id: model.id) }
            }
            Section("Flowcy voice") {
                Button(flowcy.map { "\($0.model.alias) · \($0.voice.name)…" } ?? "Choose Flowcy Model…") {
                    choosingVoice = true
                }
            }
        } label: {
            Label(player.listening ? "On Air" : "Plan Radio", systemImage: "dot.radiowaves.left.and.right")
        }
        .fixedSize()
        .help("Listen to brief updates from the debate")
        .accessibilityIdentifier("coding-plan-radio")
        .sheet(isPresented: $choosingVoice) {
            PetFlowcyVoiceSheet(client: client, isSignedIn: appState.rxAuth.isAuthenticated,
                                initialVoice: flowcy, onSelect: { choice in
                if let data = try? JSONEncoder().encode(choice) { flowcyData = data }
                if player.listening { listen() }
            })
        }
        .planningError(Bindable(player).error)
    }

    private func localChoice(_ title: String, id: String) -> some View {
        Button {
            flowcyData = Data()
            localID = id
            if player.listening { listen() }
        } label: {
            if flowcy == nil && localID == id { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func listen() {
        var voice = PetConfiguration()
        if let model = localModels.first(where: { $0.id == localID }) {
            PetVoicePresets.select(model: model, in: &voice)
        } else {
            voice.selectLocalVoice(modelID: localID)
        }
        voice.flowcyVoice = flowcy
        player.start(configuration: voice.speechSynthesisConfiguration(client: client))
        if let update = room.dispatch {
            player.receive(update.text)
        } else if let last = room.plan.contributions.last(where: { $0.model != nil }) {
            player.receive("\(last.role). \(last.radioSummary)")
        } else if let step = room.plan.nextStep, room.runID != nil {
            player.receive("\(room.plan.speaker(for: step).role) is preparing an update.")
        }
    }
}
