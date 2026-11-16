import AVFoundation
import Foundation
import os
import RxAgentVoice
import struct RxCodeCore.AudioGenerationSettings

// MARK: - Persistent MLX TTS Worker Process

private actor MLXVoiceWorker {
    private let logger = Logger(subsystem: "com.claudework", category: "MLXVoiceWorker")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var loadedModelPath: String?
    private var activeContinuations: [String: AsyncThrowingStream<VoiceAudioFrame, Error>.Continuation] = [:]
    private var workerGeneration = UUID()
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?

    func ensureStarted(
        modelDirectory: URL,
        appSupport: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        // Model preparation suspends this actor. Replacement previews must share
        // startup instead of launching two workers and losing a ready waiter.
        if let startupTask {
            try await startupTask.value
        }
        try Task.checkCancellation()
        if let process, process.isRunning, loadedModelPath == modelDirectory.path {
            return
        }
        let task = Task {
            try await startWorker(modelDirectory: modelDirectory, appSupport: appSupport, onStatus: onStatus)
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
        try Task.checkCancellation()
    }

    private func startWorker(
        modelDirectory: URL,
        appSupport: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        await shutdown()
        let token = UUID()
        workerGeneration = token

        let runtimeRoot = try await MLXMediaRuntimeInstaller.shared.prepare(
            .audio,
            appSupport: appSupport,
            status: onStatus
        )
        guard let scriptURL = Self.resolveWorkerScriptURL() else {
            throw VoiceError.unavailable("Missing bundled mlx_voice_worker.py resource.")
        }

        let proc = Process()
        proc.executableURL = runtimeRoot.appending(path: "bin/python")
        proc.arguments = ["-u", scriptURL.path, modelDirectory.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        onStatus("Warming up local voice model…")
        try proc.run()

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.loadedModelPath = modelDirectory.path

        let outHandle = outPipe.fileHandleForReading
        let outputChunks = Self.pipeChunks(outHandle)
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            var buffer = Data()
            for await chunk in outputChunks {
                guard !Task.isCancelled else { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    await self?.handleWorkerLine(line, generation: token)
                }
            }
            await self?.handleWorkerExit(generation: token)
        }

        // Drain stderr quietly for diagnostics without blocking the pipe
        let errorChunks = Self.pipeChunks(errPipe.fileHandleForReading)
        stderrTask = Task.detached(priority: .utility) { [logger] in
            for await chunk in errorChunks {
                guard !Task.isCancelled else { return }
                logger.debug("[mlx-voice] \(String(decoding: chunk, as: UTF8.self), privacy: .public)")
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyWaiter = cont
        }
    }

    private nonisolated static func pipeChunks(_ handle: FileHandle) -> AsyncStream<Data> {
        // Match ACP's pipe reader: FileHandle.bytes.lines can buffer a live
        // Darwin pipe until EOF, which a persistent voice worker never sends.
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        langCode: String,
        locale: String,
        seed: Int
    ) throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        guard let stdinHandle, let process, process.isRunning else {
            throw VoiceError.invalidState
        }
        let requestID = UUID().uuidString
        let (stream, continuation) = AsyncThrowingStream<VoiceAudioFrame, Error>.makeStream()
        activeContinuations[requestID] = continuation

        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancelRequest(id: requestID) }
            }
        }

        let payload: [String: Any] = [
            "op": "speak",
            "id": requestID,
            "text": text,
            "voice": voice,
            "speed": speed,
            "lang_code": langCode,
            // Qwen3-TTS resolves its language from the conversation locale;
            // `lang_code` follows the Kokoro preset and is only a fallback.
            "locale": locale,
            "seed": seed,
        ]
        let lineData = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
        try stdinHandle.write(contentsOf: lineData)
        return stream
    }

    func cancelAll() {
        if let stdinHandle, let data = try? JSONSerialization.data(withJSONObject: ["op": "cancel"]) {
            try? stdinHandle.write(contentsOf: data + Data([0x0A]))
        }
        let pending = activeContinuations.values
        activeContinuations.removeAll()
        for cont in pending {
            cont.finish()
        }
    }

    func shutdown() async {
        workerGeneration = UUID()
        cancelAll()
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(throwing: VoiceError.invalidState)
        }
        if let stdinHandle, let quit = try? JSONSerialization.data(withJSONObject: ["op": "quit"]) {
            try? stdinHandle.write(contentsOf: quit + Data([0x0A]))
            try? stdinHandle.close()
        }
        stdinHandle = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        loadedModelPath = nil
        readerTask?.cancel()
        readerTask = nil
        stderrTask?.cancel()
        stderrTask = nil
    }

    private func cancelRequest(id: String) {
        guard let cont = activeContinuations.removeValue(forKey: id) else { return }
        cont.finish()
        // The worker's cancel operation stops its current generation. A stale
        // stream must not cancel a newer preview that is already synthesizing.
        guard activeContinuations.isEmpty else { return }
        if let stdinHandle, let data = try? JSONSerialization.data(withJSONObject: ["op": "cancel", "id": id]) {
            try? stdinHandle.write(contentsOf: data + Data([0x0A]))
        }
    }

    private func handleWorkerLine(_ line: String, generation: UUID) {
        guard generation == workerGeneration else { return }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        switch event {
        case "ready":
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume()
            }
        case "audio":
            guard let id = json["id"] as? String,
                  let b64 = json["pcm"] as? String,
                  let pcm = Data(base64Encoded: b64),
                  let cont = activeContinuations[id],
                  let frame = try? VoiceAudioFrame(
                      data: pcm,
                      format: VoicePCMFormat(sampleRate: 24_000, channels: 1)
                  ) else {
                return
            }
            cont.yield(frame)
        case "done", "cancelled":
            if let id = json["id"] as? String, let cont = activeContinuations.removeValue(forKey: id) {
                cont.finish()
            }
        case "error":
            let message = (json["message"] as? String) ?? "MLX voice synthesis failed."
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume(throwing: VoiceError.unavailable(message))
            }
            if let id = json["id"] as? String, let cont = activeContinuations.removeValue(forKey: id) {
                cont.finish(throwing: VoiceError.transport(message))
            }
        default:
            break
        }
    }

    private func handleWorkerExit(generation: UUID) {
        guard generation == workerGeneration else { return }
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(throwing: VoiceError.transport("MLX voice worker exited unexpectedly."))
        }
        let pending = activeContinuations.values
        activeContinuations.removeAll()
        for cont in pending {
            cont.finish(throwing: VoiceError.transport("MLX voice worker exited before speech completed."))
        }
    }

    private static func resolveWorkerScriptURL() -> URL? {
        if let flat = Bundle.main.url(forResource: "mlx_voice_worker", withExtension: "py") {
            return flat
        }
        if let nested = Bundle.main.url(forResource: "mlx_voice_worker", withExtension: "py", subdirectory: "Pet") {
            return nested
        }
        let sourceCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Pet/mlx_voice_worker.py")
        if FileManager.default.fileExists(atPath: sourceCandidate.path) {
            return sourceCandidate
        }
        return nil
    }
}

// MARK: - Local Speech Synthesizer (MLX / GGUF / macOS System Voice Fallback)

actor PetLocalSpeechSynthesizer: SpeechSynthesizing {
    struct Configuration: Sendable {
        var modelID: String
        var voicePreset: String
        var systemVoiceIdentifier: String?
        var localeIdentifier: String
        var speechRate: Double
        var seed: Int = 42
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
        guard cfg.modelID != PetConfiguration.systemTTSModelID else { return }
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
    private let output = PetStandaloneAudioOutput()
    /// Speaker device UID read before each utterance; `nil` follows the system default.
    var outputDeviceUID: () -> String? = { nil }

    private var speakTask: Task<Void, Never>?
    private var generation = UUID()
    var onSpeakingStateChanged: ((Bool, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var speechPlayback: PetSpeechPlaybackSignal?

    var isSpeaking: Bool { speakTask != nil }

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
                try await self.output.prepare(deviceUID: desiredUID, envelope: self.speechPlayback?.envelope)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                var scheduledGroup = 0
                for chunk in SpokenTextChunker.speechChunks(cleaned) {
                    try Task.checkCancellation()
                    let stream = try await synthesizer.synthesize(chunk)
                    var receivedAudio = false
                    for try await frame in stream {
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        guard !frame.data.isEmpty else { continue }
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
