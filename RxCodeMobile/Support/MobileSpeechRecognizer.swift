import AVFoundation
import Observation
import Speech

/// Captures speech locally. Unsupported languages never fall back to server recognition.
@MainActor @Observable
final class MobileSpeechRecognizer {
    enum Phase { case idle, authorizing, recording, finishing }

    var transcript = ""
    private(set) var phase: Phase = .idle
    private(set) var levels = Array(repeating: Float(0), count: 40)
    var errorMessage: String?
    private(set) var needsSettings = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var hasAudioSession = false
    @ObservationIgnored private let authorizeSpeech: () async -> SFSpeechRecognizerAuthorizationStatus
    @ObservationIgnored private let authorizeMicrophone: () async -> Bool

    init(
        authorizeSpeech: @escaping () async -> SFSpeechRecognizerAuthorizationStatus = {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        },
        authorizeMicrophone: @escaping () async -> Bool = {
            await AVAudioApplication.requestRecordPermission()
        }
    ) {
        self.authorizeSpeech = authorizeSpeech
        self.authorizeMicrophone = authorizeMicrophone
    }

    var isBusy: Bool { phase != .idle }

    func start(localeIdentifier: String) async {
        guard phase == .idle, !Task.isCancelled else { return }
        let id = UUID()
        sessionID = id
        phase = .authorizing
        errorMessage = nil
        needsSettings = false

        let authorization = await authorizeSpeech()
        guard sessionID == id else { return }
        guard !Task.isCancelled else { cancel(); return }
        guard authorization == .authorized else {
            needsSettings = authorization == .denied
            fail("Speech recognition access is required. Allow Speech Recognition for RxCode in Settings.")
            return
        }
        let microphoneAllowed = await authorizeMicrophone()
        guard sessionID == id else { return }
        guard !Task.isCancelled else { cancel(); return }
        guard microphoneAllowed else {
            needsSettings = true
            fail("Microphone access is required. Allow Microphone access for RxCode in Settings.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition else {
            fail("On-device recognition is unavailable for this language on this device. Choose another language and check installed dictation languages in Settings.")
            return
        }
        guard recognizer.isAvailable else {
            fail("Speech recognition is currently unavailable. Please try again.")
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true)
            hasAudioSession = true

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("No microphone is available. Connect a microphone and try again.")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            self.recognizer = recognizer
            self.engine = engine
            let previousText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    if let text, !text.isEmpty {
                        self.transcript = previousText.isEmpty ? text : previousText + "\n" + text
                    }
                    if isFinal {
                        self.cancel()
                    } else if let message {
                        self.fail(message)
                    }
                }
            }

            // Only scalar meter values cross to the main actor; audio stays in the tap.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let level = max(0, min(1, (20 * log10(max(rms, 0.000_01)) + 55) / 55))
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id, self.phase == .recording else { return }
                    self.levels.removeFirst()
                    self.levels.append(level)
                }
            }
            engine.prepare()
            try engine.start()
            phase = .recording
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// End microphone capture, then allow the recognizer to deliver the last words.
    func finish() {
        guard phase == .recording else { return }
        phase = .finishing
        stopAudio()
        request?.endAudio()
        let id = sessionID
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            self.cancel()
        }
    }

    /// Invalidates pending permission requests and late recognition callbacks too.
    func cancel() {
        sessionID = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        stopAudio()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        request = nil
        phase = .idle
    }

    func interrupt() {
        guard isBusy else { return }
        cancel()
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
    }

    private func stopAudio() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        levels = Array(repeating: 0, count: 40)
        if hasAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            hasAudioSession = false
        }
    }
}
