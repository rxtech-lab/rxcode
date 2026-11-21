import AVFoundation
import Foundation
import os
import RxAgentVoice

// MARK: - CoreAudio Hardware Driver for VoiceSession

@MainActor
class PetVoiceAudioDriver: VoiceAudioDriver {
    // CoreAudio device discovery and graph transitions can block for hundreds of milliseconds.
    // Only access this hardware on the main actor after startup completes; stop disables
    // playback/capture callbacks before handing the graph back to the serial queue.
    private let hardware = PetVoiceAudioHardware()
    private var engine: AVAudioEngine { hardware.engine }
    private var player: AVAudioPlayerNode { hardware.player }
    private var cuePlayer: AVAudioPlayerNode { hardware.cuePlayer }
    private let outputSampleRate: Double = 24_000
    private var playbackFormat: AVAudioFormat { hardware.playbackFormat }
    private var generation = UUID()
    private var playbackGeneration = UUID()

    weak var meters: VoiceMeters?
    var speechPlayback: PetSpeechPlaybackSignal?
    var suppressesCaptureDuringPlayback: Bool = true

    private(set) var captureEnabled = false
    private(set) var isOutputMuted = false
    private var isStarted = false
    private var frameContinuation: AsyncStream<VoiceAudioFrame>.Continuation?
    private var pendingOutputBuffers = 0
    var hasPendingPlayback: Bool { pendingOutputBuffers > 0 }
    private var renderedOutputFrames: Int64 = 0
    private var echoTailDeadline: ContinuousClock.Instant = .now

    private var inputDeviceUID: String?
    private var outputDeviceUID: String?

    var realtimeDevice: PetRTCDevice? {
        didSet {
            realtimeDevice?.captureEnabled = captureEnabled
            realtimeDevice?.outputMuted = isOutputMuted
        }
    }
    var captureDidChange: ((Bool) -> Void)? {
        didSet { captureDidChange?(captureEnabled) }
    }
    private var routeChangeInProgress = false
    private var activeFormat: VoicePCMFormat?

    func selectDevices(input: String?, output: String?) async throws {
        inputDeviceUID = input
        outputDeviceUID = output
        guard !routeChangeInProgress, let activeFormat else { return }
        routeChangeInProgress = true
        defer { routeChangeInProgress = false }
        if isStarted { flush() }
        isStarted = false
        hardware.stop()
        try await startHardware(format: activeFormat, token: generation)
    }

    init(
        meters: VoiceMeters? = nil,
        suppressesCaptureDuringPlayback: Bool = true,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil
    ) {
        self.meters = meters
        self.suppressesCaptureDuringPlayback = suppressesCaptureDuringPlayback
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
    }

    var heardDuration: Duration {
        let ms = Double(renderedOutputFrames) * 1000.0 / outputSampleRate
        return .milliseconds(Int64(ms.rounded()))
    }

    func start(format: VoicePCMFormat) async throws -> AsyncStream<VoiceAudioFrame> {
        stop()
        let token = UUID()
        generation = token

        let micGranted = await Self.requestMicrophoneAccess()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        guard micGranted else {
            throw VoiceError.unavailable("Microphone permission is required for Pet Voice Mode. Grant access in System Settings → Privacy & Security → Microphone.")
        }

        let (stream, continuation) = AsyncStream<VoiceAudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(64))
        frameContinuation = continuation
        renderedOutputFrames = 0
        pendingOutputBuffers = 0

        do {
            try await startHardware(format: format, token: token)
            activeFormat = format
            return stream
        } catch {
            if generation == token { stop() }
            continuation.finish()
            throw error
        }
    }

    private func startHardware(format: VoicePCMFormat, token: UUID) async throws {
        while generation == token {
            let input = inputDeviceUID
            let output = outputDeviceUID
            try await hardware.start(
                format: format,
                inputDeviceUID: inputDeviceUID,
                outputDeviceUID: outputDeviceUID,
                realtimeDevice: realtimeDevice,
                envelope: speechPlayback?.envelope
            ) { [weak self] frame, rms in
                Task { @MainActor [weak self] in
                    guard let self, self.isStarted, self.generation == token else { return }
                    if self.shouldForwardCapturedAudio {
                        self.meters?.input = min(1.0, rms * 4.2)
                        self.frameContinuation?.yield(frame)
                    } else {
                        self.meters?.input = 0
                    }
                }
            }
            guard generation == token, !Task.isCancelled else {
                throw CancellationError()
            }
            if input == inputDeviceUID, output == outputDeviceUID {
                isStarted = true
                return
            }
            hardware.stop()
        }
        throw CancellationError()
    }

    final func play(_ frame: VoiceAudioFrame) throws {
        guard !isOutputMuted else { return }
        try schedulePlayback(frame)
    }

    func schedulePlayback(_ frame: VoiceAudioFrame) throws {
        guard isStarted else { return }
        guard frame.data.count >= 2 else { return }

        let srcRate = Double(frame.format.sampleRate)
        let channels = max(1, frame.format.channels)
        let sampleFrames = frame.data.count / (2 * channels)
        guard sampleFrames > 0 else { return }

        guard let srcBuffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcRate,
                channels: 1,
                interleaved: false
            )!,
            frameCapacity: AVAudioFrameCount(sampleFrames)
        ) else {
            throw VoiceError.invalidAudio
        }
        srcBuffer.frameLength = AVAudioFrameCount(sampleFrames)

        var sumSquares: Double = 0
        if let dst = srcBuffer.floatChannelData?[0] {
            frame.data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleFrames {
                    let s = Float(Int16(littleEndian: samples[i * channels])) / 32768.0
                    dst[i] = s
                    sumSquares += Double(s * s)
                }
            }
        }
        let rms = Float(sqrt(sumSquares / Double(sampleFrames)))
        // Mouth intensity comes from the rendered player tap, not incoming chunks.
        _ = rms
        speechPlayback?.begin()

        let outBuffer: AVAudioPCMBuffer
        if abs(srcRate - outputSampleRate) < 1 {
            outBuffer = srcBuffer
        } else if let converter = AVAudioConverter(from: srcBuffer.format, to: playbackFormat),
                  let converted = AVAudioPCMBuffer(
                      pcmFormat: playbackFormat,
                      frameCapacity: AVAudioFrameCount(Double(sampleFrames) * outputSampleRate / srcRate) + 32
                  ) {
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return srcBuffer
            }
            outBuffer = converted.frameLength > 0 ? converted : srcBuffer
        } else {
            outBuffer = srcBuffer
        }

        let scheduledFrames = Int64(outBuffer.frameLength)
        pendingOutputBuffers += 1
        if !player.isPlaying {
            player.play()
        }
        let token = playbackGeneration
        player.scheduleBuffer(outBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted, self.playbackGeneration == token else { return }
                self.renderedOutputFrames += scheduledFrames
                self.pendingOutputBuffers = max(0, self.pendingOutputBuffers - 1)
                if self.pendingOutputBuffers == 0 {
                    self.meters?.output = 0
                    self.speechPlayback?.reset()
                    self.echoTailDeadline = ContinuousClock.now.advanced(by: .milliseconds(420))
                }
            }
        }
    }

    func playToolCue() {
        guard !isOutputMuted, isStarted, engine.isRunning, !hasPendingPlayback else { return }
        guard let buffer = Self.makeToolChimeBuffer(format: playbackFormat) else { return }
        cuePlayer.stop()
        cuePlayer.play()
        cuePlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stopToolCue() {
        guard isStarted else { return }
        cuePlayer.stop()
    }

    /// Plays a short rising chime through the voice engine itself so it is never
    /// ducked or dropped by the capture session. Returns `false` when the engine isn't running.
    @discardableResult
    func playConnectedCue() -> Bool {
        guard !isOutputMuted, isStarted, engine.isRunning,
              let buffer = Self.makeConnectedChimeBuffer(format: playbackFormat) else { return false }
        if !cuePlayer.isPlaying {
            cuePlayer.play()
        }
        cuePlayer.scheduleBuffer(buffer, completionHandler: nil)
        return true
    }

    func flush() {
        // Invalidate scheduled playback completions without invalidating capture callbacks.
        playbackGeneration = UUID()
        if isStarted {
            player.stop()
            player.play()
        }
        pendingOutputBuffers = 0
        renderedOutputFrames = 0
        meters?.output = 0
        speechPlayback?.reset()
        echoTailDeadline = ContinuousClock.now.advanced(by: .milliseconds(180))
    }

    func setCaptureEnabled(_ enabled: Bool) {
        captureEnabled = enabled
        realtimeDevice?.captureEnabled = enabled
        captureDidChange?(enabled)
        if !enabled {
            meters?.input = 0
        }
    }

    func setOutputMuted(_ muted: Bool) {
        guard isOutputMuted != muted else { return }
        isOutputMuted = muted
        realtimeDevice?.outputMuted = muted
        if muted {
            flush()
            stopToolCue()
        }
    }

    func stop() {
        activeFormat = nil
        isStarted = false
        generation = UUID()
        playbackGeneration = UUID()
        hardware.stop()
        pendingOutputBuffers = 0
        renderedOutputFrames = 0
        meters?.input = 0
        meters?.output = 0
        speechPlayback?.reset()
        frameContinuation?.finish()
        frameContinuation = nil
    }

    private var shouldForwardCapturedAudio: Bool {
        guard captureEnabled else { return false }
        if suppressesCaptureDuringPlayback {
            if pendingOutputBuffers > 0 { return false }
            if ContinuousClock.now < echoTailDeadline { return false }
        }
        return true
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func makeConnectedChimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let notes: [Double] = [523.25, 659.25, 783.99] // C5 -> E5 -> G5 rising "connected" chime
        let noteDuration = 0.11
        let noteFrames = Int(sr * noteDuration)
        let count = noteFrames * notes.count
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let channelCount = Int(format.channelCount)
        guard let channels = buffer.floatChannelData else { return nil }
        for i in 0..<count {
            let noteIndex = min(notes.count - 1, i / noteFrames)
            let localT = Double(i % noteFrames) / Double(noteFrames)
            let t = Double(i) / sr
            // Fast attack, smooth decay so consecutive notes don't click.
            let env = min(1.0, localT * 20.0) * pow(1.0 - localT, 1.6) * 0.22
            let sample = Float(sin(2.0 * .pi * notes[noteIndex] * t) * env)
            for c in 0..<channelCount {
                channels[c][i] = sample
            }
        }
        return buffer
    }

    static func makeToolChimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let duration = 0.16
        let count = Int(sr * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let ch = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let split = count / 2
        for i in 0..<count {
            let t = Double(i) / sr
            let freq = i < split ? 587.33 : 880.0 // D5 -> A5 gentle chime
            let localT = Double(i % max(1, split)) / Double(max(1, split))
            let env = sin(localT * .pi) * 0.08
            ch[i] = Float(sin(2.0 * .pi * freq * t) * env)
        }
        return buffer
    }
}

// All graph mutations are serialized. The unchecked conformance covers the queue-owned
// AVFoundation objects, which are borrowed by the driver only while the graph is active.
private nonisolated final class PetVoiceAudioHardware: @unchecked Sendable {
    // Share the queue across sessions so a replacement waits for the previous device teardown.
    private static let queue = DispatchQueue(label: "com.rxlab.RxCode.pet-audio", qos: .userInitiated)
    private final class Graph {
        let inputEngine = AVAudioEngine()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let cuePlayer = AVAudioPlayerNode()
        let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
        )!
    }
    private var graph: Graph?
    var engine: AVAudioEngine { graph!.engine }
    var player: AVAudioPlayerNode { graph!.player }
    var cuePlayer: AVAudioPlayerNode { graph!.cuePlayer }
    var playbackFormat: AVAudioFormat { graph!.playbackFormat }
    private var hasTap = false
    private var hasSpeechTap = false

    func start(
        format: VoicePCMFormat,
        inputDeviceUID: String?,
        outputDeviceUID: String?,
        realtimeDevice: PetRTCDevice?,
        envelope: PetSpeechEnvelope?,
        onFrame: @escaping @Sendable (VoiceAudioFrame, Float) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async { [self] in
                do {
                    let next = Graph()
                    graph = next
                    realtimeDevice?.hardwareWillStart()
                    // Route both AUHAL units before any format is read so the graph
                    // is built against the chosen devices' native formats.
                    try PetAudioDevices.route(next.inputEngine.inputNode.audioUnit, toDeviceUID: inputDeviceUID, direction: .input)
                    try PetAudioDevices.route(engine.outputNode.audioUnit, toDeviceUID: outputDeviceUID, direction: .output)
                    if let source = realtimeDevice?.makeSource() {
                        engine.attach(source)
                        engine.connect(source, to: engine.mainMixerNode, format: playbackFormat)
                    }
                    engine.attach(player)
                    engine.attach(cuePlayer)
                    engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
                    engine.connect(cuePlayer, to: engine.mainMixerNode, format: playbackFormat)
                    let input = next.inputEngine.inputNode
                    let hwFormat = input.outputFormat(forBus: 0)
                    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                        throw VoiceError.unavailable("No active audio input device was found on this Mac.")
                    }
                    guard let target = AVAudioFormat(
                        commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRate),
                        channels: AVAudioChannelCount(format.channels), interleaved: true
                    ), let converter = AVAudioConverter(from: hwFormat, to: target) else {
                        throw VoiceError.invalidAudio
                    }
                    let tap = AudioInputTapBox(
                        converter: converter, targetFormat: target, pcmFormat: format
                    ) { frame, rms in
                        realtimeDevice?.recordPCM(frame.data)
                        onFrame(frame, rms)
                    }
                    input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { buffer, _ in
                        tap.consume(buffer)
                    }
                    hasTap = true
                    next.inputEngine.prepare()
                    try next.inputEngine.start()
                    engine.prepare()
                    try engine.start()
                    if realtimeDevice == nil, let envelope {
                        let latency = engine.outputNode.outputPresentationLatency
                        player.installTap(onBus: 0, bufferSize: 480, format: playbackFormat) { buffer, time in
                            envelope.consume(buffer, at: time, latency: latency)
                        }
                        hasSpeechTap = true
                    }
                    player.play()
                    cuePlayer.play()
                    continuation.resume()
                } catch {
                    stopGraph()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        Self.queue.async { [self] in stopGraph() }
    }

    private func stopGraph() {
        guard graph != nil else { return }
        if hasTap {
            graph?.inputEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        if hasSpeechTap {
            player.removeTap(onBus: 0)
            hasSpeechTap = false
        }
        graph?.inputEngine.stop()
        engine.stop()
        if player.engine != nil { engine.detach(player) }
        if cuePlayer.engine != nil { engine.detach(cuePlayer) }
        // Release the native audio objects here as well; their destructors can touch devices.
        graph = nil
    }
}

// MARK: - Nonisolated CoreAudio Tap Converter

private nonisolated final class AudioInputTapBox: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let pcmFormat: VoicePCMFormat
    private let onFrame: @Sendable (VoiceAudioFrame, Float) -> Void

    init(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        pcmFormat: VoicePCMFormat,
        onFrame: @escaping @Sendable (VoiceAudioFrame, Float) -> Void
    ) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.pcmFormat = pcmFormat
        self.onFrame = onFrame
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let ratio = targetFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var provided = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        let length = Int(converted.frameLength)
        guard error == nil, length > 0, let int16Ptr = converted.int16ChannelData?[0] else {
            return
        }
        let byteCount = length * pcmFormat.channels * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Ptr, count: byteCount)
        guard let voiceFrame = try? VoiceAudioFrame(data: data, format: pcmFormat) else {
            return
        }
        let rms = UtteranceDetector.rms(pcm16LE: data)
        onFrame(voiceFrame, rms)
    }
}
