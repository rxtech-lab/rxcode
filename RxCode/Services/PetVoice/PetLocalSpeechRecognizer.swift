import AVFoundation
import Foundation
import os
import RxAgentVoice
import Speech
import struct RxCodeCore.AudioGenerationSettings

// MARK: - Local Speech Recognizer (Apple On-Device Speech + Local STT Models)

actor PetLocalSpeechRecognizer: SpeechRecognizing {
    nonisolated let inputFormat = VoicePCMFormat(sampleRate: 16_000, channels: 1)

    struct Configuration: Sendable {
        var source: PetLocalSpeechSource
        var localeIdentifier: String
        var localModelID: String?
        var onPartialTranscript: (@Sendable (String) -> Void)?
        var onSpeechActivityChanged: (@Sendable (Bool) -> Void)?
    }

    private let logger = Logger(subsystem: "com.claudework", category: "PetLocalSpeechRecognizer")
    private let configProvider: @Sendable () async -> Configuration
    private var utteranceContinuation: AsyncStream<String>.Continuation?
    private var detector = UtteranceDetector()

    // Apple Speech state
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestPartialText: String = ""
    private var committedPrefixLength: Int = 0
    private var requestStartedAt: ContinuousClock.Instant = .now

    // Local Whisper / MLX-STT buffer state
    private var activeSpeechPCM = Data()
    private var preRollFrames: [Data] = []
    private let maxPreRollFrames = 8

    init(configProvider: @escaping @Sendable () async -> Configuration) {
        self.configProvider = configProvider
    }

    nonisolated func asSDKAdapter() -> LocalSpeechRecognizerAdapter {
        LocalSpeechRecognizerAdapter(
            inputFormat: inputFormat,
            start: { try await self.start() },
            append: { frame in try await self.append(frame) },
            discard: { await self.discard() },
            stop: { await self.stop() }
        )
    }

    func start() async throws -> AsyncStream<String> {
        await teardownRecognition()
        detector.reset()
        activeSpeechPCM.removeAll(keepingCapacity: false)
        preRollFrames.removeAll()

        let cfg = await configProvider()
        if cfg.source == .appleSpeech {
            let authorized = await Self.requestSpeechAuthorization()
            guard authorized else {
                throw VoiceError.unavailable("Speech Recognition permission is required for local voice mode. Enable it in System Settings → Privacy & Security → Speech Recognition.")
            }
            try setupAppleSpeechSession(localeIdentifier: cfg.localeIdentifier, onPartial: cfg.onPartialTranscript)
        } else {
            let hasModel = await MainActor.run {
                guard let id = cfg.localModelID,
                      let model = LocalModelStore.shared.model(id: id),
                      LocalAudioMode(model: model) == .transcription else {
                    return LocalModelStore.shared.installed.contains { LocalAudioMode(model: $0) == .transcription }
                }
                return true
            }
            guard hasModel else {
                throw VoiceError.unavailable("No local speech-to-text model is installed. Switch to macOS On-Device Speech or download a transcription model in Local Models.")
            }
        }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        utteranceContinuation = continuation
        return stream
    }

    func append(_ frame: VoiceAudioFrame) async throws {
        guard frame.format == inputFormat else {
            throw VoiceError.invalidAudio
        }
        let sampleCount = frame.data.count / 2
        guard sampleCount > 0 else { return }
        let duration = Double(sampleCount) / Double(inputFormat.sampleRate)
        let rms = UtteranceDetector.rms(pcm16LE: frame.data)
        let vadEvent = detector.process(rms: rms, frameDuration: duration)

        let cfg = await configProvider()

        switch cfg.source {
        case .appleSpeech:
            try handleAppleSpeechFrame(frame, vadEvent: vadEvent, cfg: cfg)
        case .localWhisperModel:
            await handleLocalModelFrame(frame, vadEvent: vadEvent, cfg: cfg)
        }
    }

    func discard() async {
        detector.reset()
        latestPartialText = ""
        committedPrefixLength = 0
        activeSpeechPCM.removeAll(keepingCapacity: false)
        preRollFrames.removeAll()
        let cfg = await configProvider()
        cfg.onPartialTranscript?("")
        cfg.onSpeechActivityChanged?(false)
        if cfg.source == .appleSpeech {
            try? restartAppleSpeechRequest(cfg: cfg)
        }
    }

    func stop() async {
        await teardownRecognition()
        utteranceContinuation?.finish()
        utteranceContinuation = nil
    }

    // MARK: - Apple Speech Pipeline

    private func setupAppleSpeechSession(
        localeIdentifier: String,
        onPartial: (@Sendable (String) -> Void)?
    ) throws {
        let locale = Locale(identifier: localeIdentifier.isEmpty ? Locale.current.identifier : localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw VoiceError.unavailable("macOS Speech Recognition is unavailable for locale \(locale.identifier).")
        }
        speechRecognizer = recognizer
        try startFreshAppleRequest(recognizer: recognizer, onPartial: onPartial)
    }

    private func startFreshAppleRequest(
        recognizer: SFSpeechRecognizer,
        onPartial: (@Sendable (String) -> Void)?
    ) throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        latestPartialText = ""
        committedPrefixLength = 0
        requestStartedAt = .now

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error as NSError?
            Task {
                await self.handleAppleRecognitionCallback(
                    text: text,
                    isFinal: isFinal,
                    errorCode: nsError?.code,
                    onPartial: onPartial
                )
            }
        }
    }

    private func handleAppleRecognitionCallback(
        text: String?,
        isFinal: Bool,
        errorCode: Int?,
        onPartial: (@Sendable (String) -> Void)?
    ) async {
        if let text {
            latestPartialText = text
            let delta = currentUncommittedUtterance(from: text)
            if !delta.isEmpty {
                onPartial?(delta)
            }
            if isFinal {
                let finalUtterance = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalUtterance.isEmpty {
                    committedPrefixLength = text.count
                    onPartial?("")
                    utteranceContinuation?.yield(finalUtterance)
                }
                let cfg = await configProvider()
                try? restartAppleSpeechRequest(cfg: cfg)
            }
        } else if errorCode != nil, !detector.isSpeaking {
            let cfg = await configProvider()
            try? restartAppleSpeechRequest(cfg: cfg)
        }
    }

    private func handleAppleSpeechFrame(
        _ frame: VoiceAudioFrame,
        vadEvent: UtteranceEvent,
        cfg: Configuration
    ) throws {
        if recognitionRequest == nil, let recognizer = speechRecognizer {
            try startFreshAppleRequest(recognizer: recognizer, onPartial: cfg.onPartialTranscript)
        }
        if let pcmBuffer = Self.makePCMBuffer(from: frame) {
            recognitionRequest?.append(pcmBuffer)
        }

        switch vadEvent {
        case .speechStarted:
            cfg.onSpeechActivityChanged?(true)
        case .speechEnded:
            cfg.onSpeechActivityChanged?(false)
            let candidate = currentUncommittedUtterance(from: latestPartialText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                committedPrefixLength = latestPartialText.count
                cfg.onPartialTranscript?("")
                utteranceContinuation?.yield(candidate)
                try restartAppleSpeechRequest(cfg: cfg)
            } else {
                // Give SFSpeechRecognizer a brief beat to flush its final hypothesis
                recognitionRequest?.endAudio()
            }
        case .idleTimeout:
            if ContinuousClock.now.duration(to: requestStartedAt) < .seconds(-50) {
                try restartAppleSpeechRequest(cfg: cfg)
            }
        case .none, .speechContinuing:
            // Proactively rotate before Apple's 60-second recognition task ceiling while silent
            if !detector.isSpeaking,
               requestStartedAt.duration(to: .now) > .seconds(52),
               currentUncommittedUtterance(from: latestPartialText).isEmpty {
                try restartAppleSpeechRequest(cfg: cfg)
            }
        }
    }

    private func restartAppleSpeechRequest(cfg: Configuration) throws {
        guard let recognizer = speechRecognizer else { return }
        try startFreshAppleRequest(recognizer: recognizer, onPartial: cfg.onPartialTranscript)
    }

    private func currentUncommittedUtterance(from fullText: String) -> String {
        guard committedPrefixLength > 0 else { return fullText }
        guard fullText.count > committedPrefixLength else { return "" }
        let idx = fullText.index(fullText.startIndex, offsetBy: min(committedPrefixLength, fullText.count))
        return String(fullText[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local Model Transcription Pipeline

    private func handleLocalModelFrame(
        _ frame: VoiceAudioFrame,
        vadEvent: UtteranceEvent,
        cfg: Configuration
    ) async {
        switch vadEvent {
        case .none, .idleTimeout:
            preRollFrames.append(frame.data)
            if preRollFrames.count > maxPreRollFrames {
                preRollFrames.removeFirst(preRollFrames.count - maxPreRollFrames)
            }
        case .speechStarted:
            cfg.onSpeechActivityChanged?(true)
            cfg.onPartialTranscript?("Listening…")
            activeSpeechPCM.removeAll(keepingCapacity: true)
            for chunk in preRollFrames {
                activeSpeechPCM.append(chunk)
            }
            preRollFrames.removeAll(keepingCapacity: true)
            activeSpeechPCM.append(frame.data)
        case .speechContinuing:
            activeSpeechPCM.append(frame.data)
        case .speechEnded:
            cfg.onSpeechActivityChanged?(false)
            activeSpeechPCM.append(frame.data)
            let captured = activeSpeechPCM
            activeSpeechPCM.removeAll(keepingCapacity: false)
            guard captured.count >= inputFormat.sampleRate * 2 / 3 else {
                cfg.onPartialTranscript?("")
                return
            }
            cfg.onPartialTranscript?("Transcribing locally…")
            if let text = await transcribeWithLocalModel(pcm16LE: captured, cfg: cfg),
               !text.isEmpty {
                cfg.onPartialTranscript?("")
                utteranceContinuation?.yield(text)
            } else {
                cfg.onPartialTranscript?("")
            }
        }
    }

    private func transcribeWithLocalModel(pcm16LE: Data, cfg: Configuration) async -> String? {
        let wavURL = FileManager.default.temporaryDirectory
            .appending(path: "rxcode-pet-stt-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            try Self.writeWAV(pcm16LE: pcm16LE, sampleRate: UInt32(inputFormat.sampleRate), channels: 1, to: wavURL)
            let jobInfo: (LocalModelInfo, URL, URL)? = await MainActor.run {
                let store = LocalModelStore.shared
                let selected = cfg.localModelID.flatMap { store.model(id: $0) }
                    ?? store.installed.first { LocalAudioMode(model: $0) == .transcription }
                guard let model = selected else { return nil }
                return (model, store.modelsRoot, store.generatedAudioRoot)
            }
            guard let (model, modelsRoot, outputDir) = jobInfo else { return nil }

            var settings = AudioGenerationSettings.load()
            let langPrefix = String(cfg.localeIdentifier.prefix(2))
            if settings.language.isEmpty {
                settings.language = langPrefix
            }

            if model.format == .mlx {
                let root = try await MLXMediaRuntimeInstaller.shared.prepare(
                    .audio,
                    appSupport: modelsRoot.deletingLastPathComponent(),
                    status: { _ in }
                )
                let outPrefix = FileManager.default.temporaryDirectory.appending(path: "pet-stt-\(UUID().uuidString)")
                let outTxt = outPrefix.appendingPathExtension("txt")
                defer { try? FileManager.default.removeItem(at: outTxt) }

                var args = [
                    "-m", "mlx_audio.stt.generate",
                    "--model", model.directory(in: modelsRoot).path,
                    "--audio", wavURL.path,
                    "--output-path", outPrefix.path,
                    "--format", "txt",
                    "--max-tokens", "256",
                ]
                if !langPrefix.isEmpty {
                    args += ["--language", langPrefix]
                }
                _ = try await StableDiffusionProcess.run(
                    cli: root.appending(path: "bin/python"),
                    arguments: args,
                    engine: "MLX STT",
                    status: { _ in }
                )
                let transcript = try String(contentsOf: outTxt, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return transcript.isEmpty ? nil : transcript
            } else {
                let prepared = try await LocalModelStore.shared.prepareAudio(
                    model: model,
                    mode: .transcription,
                    taskModel: nil,
                    report: { _, _ in }
                )
                let out = try await StableDiffusionProcess.run(
                    cli: prepared.binary,
                    arguments: prepared.recipe.transcriptionArguments(
                        model: model.primaryFile(in: modelsRoot),
                        directory: model.directory(in: modelsRoot),
                        audio: wavURL.path,
                        instruction: "Transcribe the spoken audio accurately.",
                        settings: settings
                    ),
                    engine: "llama-mtmd-cli",
                    capturesOutput: true,
                    status: { _ in }
                )
                _ = outputDir
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            logger.warning("Local STT failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func teardownRecognition() async {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        speechRecognizer = nil
        latestPartialText = ""
        committedPrefixLength = 0
        activeSpeechPCM.removeAll(keepingCapacity: false)
        preRollFrames.removeAll()
    }

    // MARK: - Helpers

    static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func makePCMBuffer(from frame: VoiceAudioFrame) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(frame.format.sampleRate),
            channels: AVAudioChannelCount(frame.format.channels),
            interleaved: true
        ) else {
            return nil
        }
        let frames = AVAudioFrameCount(frame.data.count / (2 * frame.format.channels))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        if let dst = buffer.int16ChannelData?[0] {
            frame.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(dst, base, frame.data.count)
            }
        }
        return buffer
    }

    nonisolated static func writeWAV(pcm16LE: Data, sampleRate: UInt32, channels: UInt16, to url: URL) throws {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign: UInt16 = channels * 2
        let subchunk2Size = UInt32(pcm16LE.count)
        let chunkSize = 36 + subchunk2Size

        header.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: channels.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: subchunk2Size.littleEndian) { header.append(contentsOf: $0) }

        var full = header
        full.append(pcm16LE)
        try full.write(to: url, options: .atomic)
    }
}
