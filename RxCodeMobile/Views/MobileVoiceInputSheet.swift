import AVFoundation
import Speech
import SwiftUI

/// Shared by desktop-connected chat and Flowcy Agent. Dictation only edits the draft.
struct MobileVoiceInputButton: View {
    @Binding var text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            MobileHaptics.buttonTap()
            isPresented = true
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice Input")
        .accessibilityIdentifier("voice-input-button")
        .sheet(isPresented: $isPresented) {
            MobileVoiceInputSheet { transcript in
                if text.isEmpty {
                    text = transcript
                } else {
                    text += text.last?.isWhitespace == true ? transcript : "\n" + transcript
                }
            }
            .mobileSheetPresentation()
        }
    }
}

private struct MobileVoiceInputSheet: View {
    var onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("mobile.voiceInput.locale") private var localeIdentifier = Locale.current.identifier
    @State private var speech = MobileSpeechRecognizer()
    @State private var startTask: Task<Void, Never>?
    @State private var confirmingDiscard = false
    @State private var interrupted = false

    private var hasTranscript: Bool {
        !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Label("On-device recognition", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    NavigationLink {
                        MobileVoiceLanguageView(selection: $localeIdentifier)
                    } label: {
                        Label(languageName, systemImage: "globe")
                            .font(.subheadline)
                    }
                    .disabled(speech.isBusy)
                    .accessibilityIdentifier("voice-input-language")
                }
                .padding()
                Group {
                    if hasTranscript || speech.isBusy {
                        TextEditor(text: $speech.transcript)
                            .padding(.horizontal, 12)
                            .disabled(speech.isBusy)
                            .accessibilityLabel("Voice transcript")
                            .accessibilityIdentifier("voice-input-transcript")
                    } else {
                        ContentUnavailableView(
                            "Speak Your Message",
                            systemImage: "mic",
                            description: Text("Choose a language, then start recording. Review the text before adding it to your message.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VoiceWaveform(levels: speech.levels, isRecording: speech.phase == .recording)
                    .frame(height: 64)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                recordButton
            }
            .navigationTitle("Voice Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        MobileHaptics.buttonTap()
                        speech.cancel()
                        startTask?.cancel()
                        if hasTranscript { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Message") {
                        speech.cancel()
                        onInsert(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
                        MobileHaptics.connected()
                        dismiss()
                    }
                    .disabled(!hasTranscript || speech.isBusy)
                    .accessibilityIdentifier("voice-input-insert")
                }
            }
            .overlay(alignment: .top) {
                if speech.isBusy || interrupted {
                    HStack(spacing: 8) {
                        if speech.phase == .authorizing || speech.phase == .finishing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: interrupted ? "pause.circle" : "record.circle")
                                .foregroundStyle(interrupted ? Color.secondary : Color.red)
                        }
                        Text(status).font(.caption.weight(.medium))
                    }
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 56)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .alert("Voice Input Unavailable", isPresented: Binding(
                get: { speech.errorMessage != nil },
                set: { if !$0 { speech.errorMessage = nil } }
            )) {
                if speech.needsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("OK", role: .cancel) { speech.errorMessage = nil }
            } message: {
                Text(speech.errorMessage ?? "")
            }
            .confirmationDialog("Discard voice transcript?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    MobileHaptics.buttonTap()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(speech.isBusy || hasTranscript)
        .onDisappear {
            startTask?.cancel()
            speech.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { interrupt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in interrupt() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { interrupt() }
        }
        .onChange(of: speech.errorMessage) { _, message in
            if message != nil { MobileHaptics.connectionError() }
        }
    }

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
    }

    private var recordButton: some View {
        let isRecording = speech.phase == .recording
        let title = isRecording ? String(localized: "Stop Recording") : String(localized: "Start Recording")
        return Button {
            MobileHaptics.buttonTap()
            interrupted = false
            if isRecording {
                speech.finish()
            } else {
                startTask = Task { await speech.start(localeIdentifier: localeIdentifier) }
            }
        } label: {
            Label(title, systemImage: isRecording ? "stop.fill" : "mic.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? Color.red : Color.accentColor)
        .disabled(speech.phase == .authorizing || speech.phase == .finishing)
        .accessibilityIdentifier("voice-input-record")
        .padding(.horizontal)
        .padding(.bottom)
    }

    private var status: String {
        switch speech.phase {
        case .idle: return String(localized: "Recording paused. Review or continue your message.")
        case .authorizing: return String(localized: "Requesting permission…")
        case .recording: return String(localized: "Listening on device…")
        case .finishing: return String(localized: "Finishing transcription…")
        }
    }

    private func interrupt() {
        guard speech.isBusy else { return }
        speech.interrupt()
        startTask?.cancel()
        interrupted = true
        MobileHaptics.attentionNeeded()
    }
}

private struct MobileVoiceLanguageView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    // Show Apple's full locale list; availability is validated again before capture.
    private let locales = SFSpeechRecognizer.supportedLocales().sorted {
        (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
            .localizedStandardCompare(Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier) == .orderedAscending
    }

    private var filteredLocales: [Locale] {
        locales.filter {
            search.isEmpty || $0.identifier.localizedStandardContains(search)
                || (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "").localizedStandardContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredLocales, id: \.identifier) { locale in
                    Button {
                        selection = locale.identifier
                        MobileHaptics.buttonTap()
                        dismiss()
                    } label: {
                        HStack {
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .foregroundStyle(.primary)
                            Spacer()
                            if locale.identifier.replacingOccurrences(of: "_", with: "-") == selection.replacingOccurrences(of: "_", with: "-") {
                                Image(systemName: "checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("On-device language availability depends on your device and installed dictation languages. Audio is never sent to a speech recognition server.")
            }
        }
        .overlay {
            if filteredLocales.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search)
        .navigationTitle("Recognition Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct VoiceWaveform: View {
    var levels: [Float]
    var isRecording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(isRecording ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: max(4, CGFloat(levels[index]) * geometry.size.height))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: geometry.size.height)
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: levels)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRecording ? "Microphone sound level" : "Microphone stopped")
        .accessibilityIdentifier("voice-input-waveform")
    }
}
