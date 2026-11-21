import AVFoundation
import Foundation
import os
import RxAgentVoice
import struct RxCodeCore.AudioGenerationSettings

// MARK: - Local Speech Synthesizer (MLX / GGUF / macOS System Voice Fallback)

extension PetConfiguration {
    nonisolated func speechSynthesisConfiguration(client: FlowcyMediaClient? = nil) -> PetLocalSpeechSynthesizer.Configuration {
        .init(modelID: localTTSModelID, voicePreset: localTTSVoicePreset,
              systemVoiceIdentifier: systemVoiceIdentifier,
              localeIdentifier: conversationLanguageIdentifier ?? speechLocaleIdentifier,
              speechRate: speechRate, seed: resolvedLocalTTSSeed,
              flowcyVoice: flowcyVoice, flowcyClient: client)
    }
}

actor PetLocalSpeechSynthesizer: SpeechSynthesizing {
    struct Configuration: Sendable {
        var modelID: String
        var voicePreset: String
        var systemVoiceIdentifier: String?
        var localeIdentifier: String
        var speechRate: Double
        var seed: Int = 42
        var flowcyVoice: FlowcySpeechSelection?
        var flowcyClient: FlowcyMediaClient?
        var onStatusUpdate: (@Sendable (String?) -> Void)?
    }

    static let kokoroVoicePresets: [(id: String, label: String)] = [
        ("af_heart", "Heart (US Female)"),
        ("af_bella", "Bella (US Female)"),
        ("af_nova", "Nova (US Female)"),
        ("am_adam", "Adam (US Male)"),
        ("am_michael", "Michael (US Male)"),
        ("bf_emma", "Emma (UK Female)"),
        ("bm_george", "George (UK Male)"),
        ("zf_xiaobei", "Xiaobei (Mandarin Female)"),
        ("zm_yunjian", "Yunjian (Mandarin Male)"),
    ]

    private let logger = Logger(subsystem: "com.claudework", category: "PetLocalSpeechSynthesizer")
    private let configProvider: @Sendable () async -> Configuration
    private let mlxWorker = MLXVoiceWorker()
    private var activeSystemSynth: SystemSpeechBufferBox?

    init(configProvider: @escaping @Sendable () async -> Configuration) {
        self.configProvider = configProvider
    }

    nonisolated func asSDKAdapter() -> LocalSpeechSynthesizerAdapter {
        LocalSpeechSynthesizerAdapter(
            synthesize: { text in try await self.synthesize(text) },
            cancelAll: { await self.cancelAll() }
        )
    }

    func warmUp() async {
        let cfg = await configProvider()
        guard cfg.flowcyVoice == nil, cfg.modelID != PetConfiguration.systemTTSModelID else { return }
        let resolved: (URL, URL)? = await MainActor.run {
            let store = LocalModelStore.shared
            guard let model = store.model(id: cfg.modelID), model.format == .mlx,
                  LocalAudioMode(model: model) == .speech else { return nil }
            return (model.directory(in: store.modelsRoot), store.appSupport)
        }
        guard let (directory, appSupport) = resolved else { return }
        do {
            try await mlxWorker.ensureStarted(modelDirectory: directory, appSupport: appSupport, onStatus: { _ in })
        } catch is CancellationError {
            return
        } catch {
            logger.debug("Local voice preloading failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func synthesize(_ text: String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        let cleaned = SpokenTextChunker.sanitizeForSpeech(text)
        guard !cleaned.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        let cfg = await configProvider()
        if let voice = cfg.flowcyVoice {
            guard let client = cfg.flowcyClient else {
                throw VoiceError.unavailable("Open a workspace and sign in to Flowcy to use this voice.")
            }
            let frames = try await client.speechFrames(text: cleaned, selection: voice)
            try Task.checkCancellation()
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        }
        if cfg.modelID != PetConfiguration.systemTTSModelID {
            let resolvedModel: (LocalModelInfo, URL, URL)? = await MainActor.run {
                let store = LocalModelStore.shared
                guard let model = store.model(id: cfg.modelID),
                      LocalAudioMode(model: model) == .speech else {
                    return nil
                }
                return (model, store.modelsRoot, store.appSupport)
            }

            // The user picked a local voice model. Never substitute the macOS
            // voice silently: announcements must sound like the configured voice,
            // so surface the problem instead.
            guard let (model, modelsRoot, appSupport) = resolvedModel else {
                cfg.onStatusUpdate?(nil)
                throw VoiceError.unavailable(
                    "The selected voice model is not installed. Choose another Voice Model in Pet & Voice Settings → Voice."
                )
            }
            if model.format == .mlx {
                do {
                    try await mlxWorker.ensureStarted(
                        modelDirectory: model.directory(in: modelsRoot),
                        appSupport: appSupport,
                        onStatus: { message in cfg.onStatusUpdate?(message) }
                    )
                    cfg.onStatusUpdate?(nil)
                    // A replaced preview can finish warming after its
                    // replacement has already submitted speech to the worker.
                    try Task.checkCancellation()
                    let langCode = Self.mlxLangCode(voicePreset: cfg.voicePreset, locale: cfg.localeIdentifier)
                    return try await mlxWorker.synthesize(
                        text: cleaned,
                        voice: cfg.voicePreset,
                        speed: max(0.6, min(1.6, cfg.speechRate)),
                        langCode: langCode,
                        locale: cfg.localeIdentifier,
                        seed: cfg.seed
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    cfg.onStatusUpdate?(nil)
                    logger.warning("MLX TTS failed: \(error.localizedDescription, privacy: .public)")
                    throw VoiceError.unavailable("\(model.displayName) could not speak: \(error.localizedDescription)")
                }
            } else {
                do {
                    return try await synthesizeWithGGUF(text: cleaned, model: model, modelsRoot: modelsRoot, cfg: cfg)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    cfg.onStatusUpdate?(nil)
                    logger.warning("GGUF llama-tts failed: \(error.localizedDescription, privacy: .public)")
                    throw VoiceError.unavailable("\(model.displayName) could not speak: \(error.localizedDescription)")
                }
            }
        }

        cfg.onStatusUpdate?(nil)
        if cfg.systemVoiceIdentifier == PetConfiguration.spokenContentSystemVoiceID {
            return try await PetSpokenContentSpeech.stream(text: cleaned, rateMultiplier: cfg.speechRate)
        }
        return await synthesizeWithSystemVoice(text: cleaned, cfg: cfg)
    }

    func cancelAll() async {
        await mlxWorker.cancelAll()
        if let box = activeSystemSynth {
            activeSystemSynth = nil
            await box.stop()
        }
    }

    func shutdown() async {
        await cancelAll()
        await mlxWorker.shutdown()
    }

    // MARK: - GGUF llama-tts Path

    private func synthesizeWithGGUF(
        text: String,
        model: LocalModelInfo,
        modelsRoot: URL,
        cfg: Configuration
    ) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        cfg.onStatusUpdate?("Preparing GGUF voice model…")
        let prepared = try await LocalModelStore.shared.prepareAudio(
            model: model,
            mode: .speech,
            taskModel: nil,
            report: { status, _ in cfg.onStatusUpdate?(status) }
        )
        let wavURL = FileManager.default.temporaryDirectory
            .appending(path: "rxcode-pet-tts-\(UUID().uuidString).wav")

        var settings = AudioGenerationSettings.load()
        if !cfg.voicePreset.isEmpty {
            settings.voice = cfg.voicePreset
        }
        let args = prepared.recipe.speechArguments(
            model: model.primaryFile(in: modelsRoot),
            directory: model.directory(in: modelsRoot),
            text: text,
            output: wavURL,
            settings: settings,
            seed: cfg.seed
        )
        try await StableDiffusionProcess.run(
            cli: prepared.binary,
            arguments: args,
            engine: "llama-tts",
            status: { cfg.onStatusUpdate?($0) }
        )
        cfg.onStatusUpdate?(nil)
        let frames = try Self.decodeAudioFileTo24kFrames(url: wavURL)
        try? FileManager.default.removeItem(at: wavURL)

        return AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    // MARK: - macOS System Voice Fallback (`AVSpeechSynthesizer.write`)

    private func synthesizeWithSystemVoice(
        text: String,
        cfg: Configuration
    ) async -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<VoiceAudioFrame, Error>.makeStream()
        let box = await MainActor.run {
            SystemSpeechBufferBox(
                text: text,
                voiceIdentifier: cfg.systemVoiceIdentifier,
                localeIdentifier: cfg.localeIdentifier,
                rateMultiplier: cfg.speechRate,
                continuation: continuation
            )
        }
        activeSystemSynth = box
        continuation.onTermination = { _ in
            Task { await box.stop() }
        }
        await box.start()
        return stream
    }

    private static func mlxLangCode(voicePreset: String, locale: String) -> String {
        if let first = voicePreset.first {
            switch first {
            case "a": return "a"
            case "b": return "b"
            case "z": return "z"
            case "j": return "j"
            default: break
            }
        }
        if locale.lowercased().hasPrefix("zh") { return "z" }
        if locale.lowercased().hasPrefix("en-gb") || locale.lowercased().hasPrefix("en_gb") { return "b" }
        return "a"
    }

    nonisolated static func decodeAudioFileTo24kFrames(url: URL) throws -> [VoiceAudioFrame] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: srcBuffer)
        let converter = PetSpeechPCMConverter()
        return try converter.convert(srcBuffer) + converter.finish()
    }

    nonisolated static func convertBufferTo24kFrames(_ buffer: AVAudioPCMBuffer) -> [VoiceAudioFrame] {
        let converter = PetSpeechPCMConverter()
        return (try? converter.convert(buffer) + converter.finish()) ?? []
    }
}

/// Keeps the resampler's filter history for an entire utterance. AVSpeech's
/// callback buffers are contiguous audio, not independent audio files.
nonisolated final class PetSpeechPCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [VoiceAudioFrame] {
        try lock.withLock {
            guard buffer.frameLength > 0 else { return [] }
            if converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter, converter.inputFormat == buffer.format else {
                throw VoiceError.invalidAudio
            }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24_000 / buffer.format.sampleRate)) + 512
            var supplied = false
            return try render(converter, capacity: capacity) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
        }
    }

    func finish() throws -> [VoiceAudioFrame] {
        try lock.withLock {
            guard let converter else { return [] }
            defer { self.converter = nil }
            return try render(converter, capacity: 4096) { _, status in
                status.pointee = .endOfStream
                return nil
            }
        }
    }

    private func render(
        _ converter: AVAudioConverter,
        capacity: AVAudioFrameCount,
        input: AVAudioConverterInputBlock
    ) throws -> [VoiceAudioFrame] {
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw VoiceError.invalidAudio
        }
        var error: NSError?
        let status = converter.convert(to: converted, error: &error, withInputFrom: input)
        if let error { throw error }
        guard status != .error else { throw VoiceError.invalidAudio }

        let totalSamples = Int(converted.frameLength)
        guard totalSamples > 0, let ptr = converted.int16ChannelData?[0] else {
            return []
        }

        let pcmFormat = VoicePCMFormat(sampleRate: 24_000, channels: 1)
        let chunkSamples = 2_400 // 100 ms chunks
        var frames: [VoiceAudioFrame] = []
        var offset = 0
        while offset < totalSamples {
            let count = min(chunkSamples, totalSamples - offset)
            let data = Data(bytes: ptr.advanced(by: offset), count: count * MemoryLayout<Int16>.size)
            if let frame = try? VoiceAudioFrame(data: data, format: pcmFormat) {
                frames.append(frame)
            }
            offset += count
        }
        return frames
    }
}

// MARK: - MainActor Wrapper for AVSpeechSynthesizer Buffer Rendering

@MainActor
private final class SystemSpeechBufferBox {
    private let synthesizer = AVSpeechSynthesizer()
    private let text: String
    private let voiceIdentifier: String?
    private let localeIdentifier: String
    private let rateMultiplier: Double
    private let continuation: AsyncThrowingStream<VoiceAudioFrame, Error>.Continuation
    private var finished = false
    private let pcmConverter = PetSpeechPCMConverter()

    init(
        text: String,
        voiceIdentifier: String?,
        localeIdentifier: String,
        rateMultiplier: Double,
        continuation: AsyncThrowingStream<VoiceAudioFrame, Error>.Continuation
    ) {
        self.text = text
        self.voiceIdentifier = voiceIdentifier
        self.localeIdentifier = localeIdentifier
        self.rateMultiplier = rateMultiplier
        self.continuation = continuation
    }

    func start() {
        let utterance = AVSpeechUtterance(string: text)
        if let id = voiceIdentifier, !id.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            let lang = localeIdentifier.replacingOccurrences(of: "_", with: "-")
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        let scaled = Float(rateMultiplier) * AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate * 0.85, max(AVSpeechUtteranceMinimumSpeechRate, scaled))

        let cont = continuation
        let converter = pcmConverter
        synthesizer.write(utterance) { buffer in
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            do {
                if pcmBuffer.frameLength == 0 {
                    for frame in try converter.finish() { cont.yield(frame) }
                    cont.finish()
                } else {
                    for frame in try converter.convert(pcmBuffer) { cont.yield(frame) }
                }
            } catch {
                cont.finish(throwing: error)
            }
        }
    }

    func stop() {
        guard !finished else { return }
        finished = true
        synthesizer.stopSpeaking(at: .immediate)
        continuation.finish()
    }
}

// MARK: - Standalone Output Speaker (Proactive Talk, Daily Report & Previews)

/// Plays synthesized speech through a lightweight output-only `AVAudioEngine`
/// without opening the microphone — used for proactive completion announcements,
/// Daily Reports, and Voice Model previews when a live voice call is not active.
@MainActor
final class PetStandaloneSpeaker {
    private let output: any PetSpeechOutput
    /// Speaker device UID read before each utterance; `nil` follows the system default.
    var outputDeviceUID: () -> String? = { nil }

    private var speakTask: Task<Void, Never>?
    private var generation = UUID()
    var onSpeakingStateChanged: ((Bool, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var speechPlayback: PetSpeechPlaybackSignal?

    var isSpeaking: Bool { speakTask != nil }

    init(output: any PetSpeechOutput = PetStandaloneAudioOutput()) {
        self.output = output
    }

    deinit {
        output.teardown()
    }

    func speak(
        text: String,
        synthesizer: PetLocalSpeechSynthesizer
    ) {
        stop()
        let cleaned = SpokenTextChunker.sanitizeForSpeech(text)
        guard !cleaned.isEmpty else { return }

        let desiredUID = outputDeviceUID().flatMap { $0.isEmpty ? nil : $0 }
        let token = generation
        onSpeakingStateChanged?(true, 0)
        speakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                var outputPrepared = false
                var scheduledGroup = 0
                for chunk in SpokenTextChunker.speechChunks(cleaned) {
                    try Task.checkCancellation()
                    let stream = try await synthesizer.synthesize(chunk)
                    var receivedAudio = false
                    for try await frame in stream {
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        guard !frame.data.isEmpty else { continue }
                        // Synthesis can fail before producing audio (for example, a missing
                        // model). Do not open a hardware graph on that error path.
                        if !outputPrepared {
                            try await self.output.prepare(deviceUID: desiredUID, envelope: self.speechPlayback?.envelope)
                            try Task.checkCancellation()
                            guard self.generation == token else { return }
                            outputPrepared = true
                        }
                        receivedAudio = true
                        scheduledGroup += 1
                        self.speechPlayback?.begin()
                        self.output.schedule(frame.data) { [weak self] in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == token else { return }
                                scheduledGroup = max(0, scheduledGroup - 1)
                                if scheduledGroup == 0 { self.speechPlayback?.reset() }
                            }
                        }
                    }
                    guard receivedAudio else {
                        throw VoiceError.unavailable("The selected voice produced no audio. Try another voice or check that its model is installed.")
                    }
                }
                // Wait until scheduled audio finishes playing out
                while scheduledGroup > 0 && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(60))
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.output.stop()
                self.onFailure?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            guard self.generation == token, !Task.isCancelled else { return }
            self.speechPlayback?.reset()
            self.speakTask = nil
            self.onSpeakingStateChanged?(false, 0)
        }
    }

    func stop() {
        speechPlayback?.reset()
        generation = UUID()
        speakTask?.cancel()
        speakTask = nil
        output.stop()
        onSpeakingStateChanged?(false, 0)
    }

    func teardown() {
        stop()
        output.teardown()
    }
}
