import AppKit
import AVFoundation
import SwiftUI

// MARK: - Apple Voice Configuration Sheet

/// Edits a draft Apple voice selection so cancelling leaves the active voice untouched.
struct PetAppleVoiceSheet: View {
    @Bindable var controller: PetController
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var draftVoiceID: String?
    @State private var draftRate: Double = 1.0
    @State private var searchText = ""
    @State private var matchLanguageOnly = true
    @State private var showNoveltyVoices = false
    @State private var systemVoices = AVSpeechSynthesisVoice.speechVoices()
    @State private var personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    @State private var preview = PetVoiceDraftPreview()

    private var spokenLocale: String {
        controller.configuration.speechLocaleIdentifier.replacingOccurrences(of: "_", with: "-")
    }

    private var spokenLanguageCode: String? {
        Locale(identifier: spokenLocale).language.languageCode?.identifier
    }

    private var spokenLanguageName: String {
        guard let code = spokenLanguageCode else { return spokenLocale }
        return Locale.current.localizedString(forLanguageCode: code) ?? spokenLocale
    }

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return systemVoices
            .filter { voice in
                if !showNoveltyVoices, voice.voiceTraits.contains(.isNoveltyVoice) { return false }
                if matchLanguageOnly, let code = spokenLanguageCode,
                   Locale(identifier: voice.language).language.languageCode?.identifier != code {
                    return false
                }
                guard !query.isEmpty else { return true }
                return voice.name.localizedCaseInsensitiveContains(query)
                    || voice.language.localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                let lhsExact = lhs.language.caseInsensitiveCompare(spokenLocale) == .orderedSame
                let rhsExact = rhs.language.caseInsensitiveCompare(spokenLocale) == .orderedSame
                if lhsExact != rhsExact { return lhsExact }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var personalVoices: [AVSpeechSynthesisVoice] {
        filteredVoices.filter { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    private func voices(quality: AVSpeechSynthesisVoiceQuality) -> [AVSpeechSynthesisVoice] {
        filteredVoices.filter { $0.quality == quality && !$0.voiceTraits.contains(.isPersonalVoice) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    voiceRow(
                        id: PetConfiguration.spokenContentSystemVoiceID,
                        title: "Spoken Content System Voice",
                        subtitle: "Uses the System Voice from Read & Speak. Choose a Siri voice there to use Siri here.",
                        badge: "Siri"
                    )
                    voiceRow(
                        id: nil,
                        title: "Automatic for \(spokenLanguageName)",
                        subtitle: "Best installed voice for the spoken language.",
                        badge: nil
                    )
                    Link("Open Read & Speak Settings…", destination: Self.spokenContentSettingsURL)
                } header: {
                    Text("System")
                } footer: {
                    Text("macOS doesn't list Siri voices for apps. To use a Siri voice, select it as the System Voice in System Settings → Accessibility → Read & Speak, then choose Spoken Content System Voice here. Speech speed may not apply to every Siri voice.")
                }

                Section {
                    TextField("Search Voices", text: $searchText)
                    Toggle("Only \(spokenLanguageName) Voices", isOn: $matchLanguageOnly)
                    Toggle("Show Novelty Voices", isOn: $showNoveltyVoices)
                    LabeledContent("Speech Speed") {
                        HStack(spacing: 10) {
                            Slider(value: $draftRate, in: 0.75...1.35, step: 0.05)
                                .frame(maxWidth: 200)
                            Text(String(format: "%.2fx", draftRate))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("Filter")
                }

                personalVoiceSection

                qualitySection("Premium", voices(quality: .premium))
                qualitySection("Enhanced", voices(quality: .enhanced))
                qualitySection("Standard", voices(quality: .default))

                if filteredVoices.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Matching Voices", systemImage: "speaker.slash")
                        } description: {
                            Text("Download more voices in Read & Speak settings, or turn off the language filter.")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Apple Voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Voice") {
                        controller.configuration.localTTSModelID = PetConfiguration.systemTTSModelID
                        controller.configuration.systemVoiceIdentifier = draftVoiceID
                        controller.configuration.speechRate = draftRate
                        onSaved()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: .infinity,
               minHeight: 560, idealHeight: 660, maxHeight: .infinity)
        .overlay {
            if preview.isPlaying {
                PetActionStatusOverlay(message: preview.status ?? "Previewing voice…")
            }
        }
        .alert("Voice Preview Failed", isPresented: Binding(
            get: { preview.errorMessage != nil },
            set: { if !$0 { preview.errorMessage = nil } }
        )) {
            Button("OK") { preview.errorMessage = nil }
        } message: {
            Text(preview.errorMessage ?? "")
        }
        .onAppear {
            draftVoiceID = controller.configuration.systemVoiceIdentifier
            draftRate = controller.configuration.speechRate
        }
        .onDisappear { preview.shutdown() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshVoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            refreshVoices()
        }
    }

    private static let spokenContentSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"
    )!

    @ViewBuilder
    private var personalVoiceSection: some View {
        if !personalVoices.isEmpty || personalVoiceStatus != .authorized {
            Section {
                ForEach(personalVoices, id: \.identifier) { voice in
                    voiceRow(id: voice.identifier, title: voice.name, subtitle: voice.language, badge: "Personal")
                }
                switch personalVoiceStatus {
                case .notDetermined:
                    Button("Allow Personal Voice…") {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            Task { @MainActor in
                                personalVoiceStatus = status
                                refreshVoices()
                            }
                        }
                    }
                case .denied:
                    Text("Personal Voice access is off. Turn it on in System Settings → Privacy & Security → Personal Voice.")
                        .foregroundStyle(.secondary)
                case .unsupported:
                    Text("Personal Voice isn't supported on this Mac.")
                        .foregroundStyle(.secondary)
                default:
                    if personalVoices.isEmpty {
                        Text("No Personal Voice found. Create one in System Settings → Accessibility → Personal Voice.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Personal Voice")
            }
        }
    }

    @ViewBuilder
    private func qualitySection(_ title: String, _ voices: [AVSpeechSynthesisVoice]) -> some View {
        if !voices.isEmpty {
            Section(title) {
                ForEach(voices, id: \.identifier) { voice in
                    voiceRow(
                        id: voice.identifier,
                        title: voice.name,
                        subtitle: voiceSubtitle(voice),
                        badge: nil
                    )
                }
            }
        }
    }

    private func voiceSubtitle(_ voice: AVSpeechSynthesisVoice) -> String {
        let languageName = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let gender: String
        switch voice.gender {
        case .female: gender = " · Female"
        case .male: gender = " · Male"
        default: gender = ""
        }
        return "\(languageName)\(gender)"
    }

    private func voiceRow(id: String?, title: String, subtitle: String, badge: String?) -> some View {
        let isSelected = draftVoiceID == id
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview") { play(voiceID: id) }
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture { draftVoiceID = id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { draftVoiceID = id }
    }

    private func play(voiceID: String?) {
        draftVoiceID = voiceID
        var draft = controller.configuration
        draft.localTTSModelID = PetConfiguration.systemTTSModelID
        draft.systemVoiceIdentifier = voiceID
        draft.speechRate = draftRate
        preview.play(configuration: draft, controller: controller)
    }

    private func refreshVoices() {
        systemVoices = AVSpeechSynthesisVoice.speechVoices()
        personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    }
}

// MARK: - Codex Realtime Voice Configuration Sheet

/// Edits a draft Codex Realtime voice so cancelling leaves the active voice untouched.
struct PetCodexVoiceSheet: View {
    @Bindable var controller: PetController
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var draftVoice: CodexRealtimeVoicePreset = .defaultVoice
    @State private var draftTransport: CodexRealtimeTransportPreference = .webRTC
    @State private var draftModel = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CodexRealtimeVoicePreset.allCases) { preset in
                        HStack(spacing: 12) {
                            Image(systemName: draftVoice == preset ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(draftVoice == preset ? Color.accentColor : .secondary)
                                .font(.system(size: 16))
                            Text(preset.displayName)
                            if preset == .defaultVoice {
                                Text("Default")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { draftVoice = preset }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(draftVoice == preset ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { draftVoice = preset }
                    }
                } header: {
                    Text("Realtime Voice")
                } footer: {
                    Text("Codex Realtime voices are generated by the Codex session, so there's no offline preview. The new voice applies the next time voice mode starts. Notifications spoken outside a live session use the Apple or neural voice.")
                }

                Section("Connection") {
                    Picker("Transport", selection: $draftTransport) {
                        ForEach(CodexRealtimeTransportPreference.allCases) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    TextField("Realtime Model Override", text: $draftModel, prompt: Text("Managed by Codex"))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Codex Realtime Voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        controller.configuration.codexVoice = draftVoice.rawValue
                        controller.configuration.codexTransport = draftTransport
                        controller.configuration.codexRealtimeModel = draftModel
                        onSaved()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity,
               minHeight: 520, idealHeight: 620, maxHeight: .infinity)
        .onAppear {
            draftVoice = controller.configuration.resolvedCodexVoice
            draftTransport = controller.configuration.codexTransport
            draftModel = controller.configuration.codexRealtimeModel
        }
    }
}
