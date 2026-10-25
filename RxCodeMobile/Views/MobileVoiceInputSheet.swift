import AVFoundation
import Observation
import Speech
import SwiftUI

/// Drives the iMessage-style composer: idle text field → live recording → review before sending.
@MainActor @Observable
final class MobileVoiceInputSession {
    enum Mode { case idle, recording, review }

    let speech = MobileSpeechRecognizer()
    var mode: Mode = .idle
    var showingSettings = false
    private(set) var startedAt = Date()
    private(set) var duration: TimeInterval = 0
    private(set) var recordedLevels: [Float] = []
    private var originalDraft = ""
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    var isPresented: Bool { mode != .idle }

    var draft: String {
        guard !speech.transcript.isEmpty else { return originalDraft }
        let separator = originalDraft.isEmpty || originalDraft.last?.isWhitespace == true ? "" : "\n"
        return originalDraft + separator + speech.transcript
    }

    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func begin(draft: String, locale: String) {
        MobileHaptics.buttonTap()
        originalDraft = draft
        speech.transcript = ""
        speech.resetHistory()
        recordedLevels = []
        duration = 0
        startedAt = .now
        pausedAt = nil
        mode = .recording
        resume(locale: locale)
    }

    func resume(locale: String) {
        if let pausedAt {
            startedAt += Date.now.timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        startTask = Task { await speech.start(localeIdentifier: locale) }
    }

    /// Recording pauses while the language sheet is open and resumes when it closes.
    func openSettings() {
        MobileHaptics.buttonTap()
        showingSettings = true
        guard mode == .recording else { return }
        pausedAt = .now
        startTask?.cancel()
        speech.cancel()
        speech.errorMessage = nil
    }

    /// Ends capture; `captureEnded()` moves to review once the recognizer delivers its last words.
    func stop() {
        MobileHaptics.buttonTap()
        duration = Date.now.timeIntervalSince(startedAt)
        if speech.phase == .recording {
            speech.finish()
        } else {
            startTask?.cancel()
            speech.cancel()
            captureEnded()
        }
    }

    /// Backgrounding, audio interruptions and lost input devices keep the partial transcript for review.
    func interrupt() {
        guard mode == .recording else { return }
        duration = Date.now.timeIntervalSince(startedAt)
        startTask?.cancel()
        speech.cancel()
        captureEnded()
    }

    func captureEnded() {
        guard mode == .recording, !showingSettings, speech.phase == .idle else { return }
        guard speech.errorMessage == nil else {
            mode = .idle
            return
        }
        if duration == 0 { duration = Date.now.timeIntervalSince(startedAt) }
        recordedLevels = Self.downsample(speech.history, to: 32)
        mode = .review
        MobileHaptics.connected()
    }

    /// Returns the text that was in the composer before recording started.
    func discard() -> String {
        mode = .idle
        startTask?.cancel()
        speech.cancel()
        return originalDraft
    }

    func endReview() {
        mode = .idle
    }

    private static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0.1, count: count) }
        return (0..<count).map { index in
            let lower = index * samples.count / count
            let upper = max(lower + 1, (index + 1) * samples.count / count)
            return samples[lower..<min(upper, samples.count)].max() ?? 0
        }
    }
}

extension View {
    /// Language sheet, permission alerts, draft syncing and audio lifecycle for a voice composer.
    func mobileVoiceInput(session: MobileVoiceInputSession, text: Binding<String>) -> some View {
        modifier(MobileVoiceInputModifier(text: text, session: session))
    }
}

private struct MobileVoiceInputModifier: ViewModifier {
    @Binding var text: String
    var session: MobileVoiceInputSession

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage(MobileVoiceLocale.storageKey) private var localeIdentifier = Locale.current.identifier

    func body(content: Content) -> some View {
        @Bindable var session = session
        content
            .sheet(isPresented: $session.showingSettings, onDismiss: {
                if session.mode == .recording { session.resume(locale: localeIdentifier) }
            }) {
                NavigationStack {
                    MobileVoiceLanguageView(selection: $localeIdentifier)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { MobileHaptics.buttonTap(); session.showingSettings = false }
                            }
                        }
                }
                .mobileSheetPresentation()
            }
            .alert("Voice Input Unavailable", isPresented: Binding(
                get: { session.speech.errorMessage != nil },
                set: { if !$0 { session.speech.errorMessage = nil } }
            )) {
                Button("Language Settings") { session.openSettings() }
                if session.speech.needsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("OK", role: .cancel) { session.speech.errorMessage = nil }
            } message: {
                Text(session.speech.errorMessage ?? "")
            }
            .onChange(of: session.speech.transcript) { _, _ in
                if session.mode == .recording { text = session.draft }
            }
            .onChange(of: session.speech.phase) { _, phase in
                if phase == .idle { session.captureEnded() }
            }
            .onChange(of: session.speech.errorMessage) { _, message in
                if message != nil { MobileHaptics.connectionError() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { session.interrupt() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in session.interrupt() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { session.interrupt() }
            }
            .onDisappear {
                guard session.mode == .recording else { return }
                text = session.draft
                _ = session.discard()
            }
    }
}

enum MobileVoiceLocale {
    static let storageKey = "mobile.voiceInput.locale"

    static func shortName(_ identifier: String) -> String {
        Locale(identifier: identifier).language.languageCode?.identifier.uppercased() ?? identifier
    }
}

/// Mic, Send and Stop share one footprint at the trailing edge of the composer capsule.
struct MobileComposerButton: View {
    enum Style { case accent, plain, destructive }

    static let size: CGFloat = 36

    let title: LocalizedStringKey
    let systemImage: String
    var style: Style = .plain
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, systemImage: String, style: Style = .plain, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: style == .plain ? 20 : 16, weight: .bold))
                .foregroundStyle(style == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                .frame(width: Self.size, height: Self.size)
                .background(fill, in: Circle())
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .accent: AnyShapeStyle(Color.accentColor)
        case .plain: AnyShapeStyle(Color.clear)
        case .destructive: AnyShapeStyle(Color.red)
        }
    }
}

/// Glass circle that sits beside the composer capsule (cancel recording, stop streaming).
struct MobileComposerSideButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .glassEffect(.regular.tint(tint?.opacity(0.2)).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct MobileVoiceMicButton: View {
    @Binding var text: String
    var session: MobileVoiceInputSession
    @AppStorage(MobileVoiceLocale.storageKey) private var localeIdentifier = Locale.current.identifier

    var body: some View {
        MobileComposerButton("Voice Input", systemImage: "waveform") {
            session.begin(draft: text, locale: localeIdentifier)
        }
        .accessibilityIdentifier("voice-input-button")
        .contextMenu {
            Button("Recognition Language", systemImage: "globe") { session.openSettings() }
        }
    }
}

struct MobileVoiceCancelButton: View {
    var action: () -> Void

    var body: some View {
        MobileComposerSideButton(title: "Discard Voice Message", systemImage: "xmark") {
            MobileHaptics.buttonTap()
            action()
        }
            .accessibilityIdentifier("voice-input-cancel")
    }
}

/// Live recording content that takes the text field's place inside the composer capsule.
struct MobileVoiceRecordingContent: View {
    var session: MobileVoiceInputSession
    @AppStorage(MobileVoiceLocale.storageKey) private var localeIdentifier = Locale.current.identifier

    private var isRecording: Bool { session.speech.phase == .recording }
    private var isPreparing: Bool {
        session.speech.phase == .authorizing || session.speech.phase == .finishing
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: isRecording)
                .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(session.startedAt)))
                Text(MobileVoiceDuration.format(TimeInterval(seconds)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Recording duration")
            }
            VoiceWaveform(levels: session.speech.levels, isRecording: isRecording)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            Button {
                session.openSettings()
            } label: {
                Text(MobileVoiceLocale.shortName(localeIdentifier))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recognition Language")
            .accessibilityValue(Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier)
            .accessibilityIdentifier("voice-input-settings")
            ZStack {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(session.speech.phase == .authorizing ? "Requesting permission…" : "Finishing…")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    MobileComposerButton("Stop Recording", systemImage: "stop.fill", style: .destructive) {
                        session.stop()
                    }
                    .accessibilityIdentifier("voice-input-stop")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: MobileComposerButton.size, height: MobileComposerButton.size)
            .animation(.snappy, value: isPreparing)
        }
        .frame(minHeight: MobileComposerButton.size)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-input-recording-bar")
    }
}

/// After Stop: the recorded waveform with Send, and the transcription beneath it.
struct MobileVoiceReviewContent: View {
    var session: MobileVoiceInputSession
    var canSend: Bool
    var onSend: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RecordedWaveform(levels: session.recordedLevels)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                Text(MobileVoiceDuration.format(session.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                MobileComposerButton("Send Voice Message", systemImage: "arrow.up", style: .accent) {
                    MobileHaptics.buttonTap()
                    onSend()
                }
                .disabled(!canSend || !session.hasDraft)
                .accessibilityIdentifier("voice-input-send")
            }
            Button {
                MobileHaptics.buttonTap()
                onEdit()
            } label: {
                Text(session.hasDraft ? session.draft : String(localized: "No speech detected"))
                    .font(.body)
                    .foregroundStyle(session.hasDraft ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit the transcribed text")
            .accessibilityIdentifier("voice-input-transcript")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-input-review")
    }
}

enum MobileVoiceDuration {
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
            HStack(spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(isRecording ? Color.red.opacity(0.65) : Color.secondary.opacity(0.3))
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

/// Static waveform of a finished recording; bars grow in when review appears.
private struct RecordedWaveform: View {
    var levels: [Float]
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(height: max(3, CGFloat(revealed ? levels[index] : 0.05) * geometry.size.height))
                        .frame(maxWidth: .infinity)
                        .animation(
                            reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3).delay(Double(index) * 0.012),
                            value: revealed
                        )
                }
            }
            .frame(height: geometry.size.height)
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorded audio waveform")
        .accessibilityIdentifier("voice-input-recorded-waveform")
    }
}
