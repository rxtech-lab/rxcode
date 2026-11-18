import AVFoundation
import Foundation

nonisolated protocol PetSpeechOutput: Sendable {
    func prepare(deviceUID: String?, envelope: PetSpeechEnvelope?) async throws
    func schedule(_ data: Data, completion: @escaping @Sendable () -> Void)
    func stop()
    func teardown()
}

/// AVFAudio may synchronously wait for its internal default-QoS threads. Confine
/// the entire graph to this queue so playback control never blocks the UI thread.
/// All mutable state and AVFAudio objects are accessed only on `queue`.
nonisolated final class PetStandaloneAudioOutput: PetSpeechOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.rxlab.pet.speech-output", qos: .default)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var routedDeviceUID: String?
    private var hasTap = false

    func prepare(deviceUID: String?, envelope: PetSpeechEnvelope?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async(qos: .default, flags: .enforceQoS) { [self] in
                do {
                    try configure(deviceUID: deviceUID, envelope: envelope)
                    continuation.resume()
                } catch {
                    destroyGraph()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func schedule(_ data: Data, completion: @escaping @Sendable () -> Void) {
        queue.async(qos: .default, flags: .enforceQoS) { [self] in
            guard let player, let buffer = makeBuffer(data) else {
                completion()
                return
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
            if !player.isPlaying { player.play() }
        }
    }

    func stop() {
        queue.async(qos: .default, flags: .enforceQoS) { [self] in player?.stop() }
    }

    func teardown() {
        queue.async(qos: .default, flags: .enforceQoS) { [self] in destroyGraph() }
    }

    private func configure(deviceUID: String?, envelope: PetSpeechEnvelope?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if engine != nil, deviceUID != routedDeviceUID { destroyGraph() }
        if let engine {
            if !engine.isRunning { try engine.start() }
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.engine = engine
        self.player = player
        routedDeviceUID = deviceUID
        try PetAudioDevices.route(engine.outputNode.audioUnit, toDeviceUID: deviceUID, direction: .output)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        engine.prepare()
        try engine.start()
        if let envelope {
            let latency = engine.outputNode.outputPresentationLatency
            player.installTap(onBus: 0, bufferSize: 480, format: Self.format) { buffer, time in
                envelope.consume(buffer, at: time, latency: latency)
            }
            hasTap = true
        }
    }

    private func destroyGraph() {
        dispatchPrecondition(condition: .onQueue(queue))
        player?.stop()
        engine?.stop()
        if let player {
            if hasTap { player.removeTap(onBus: 0) }
            engine?.detach(player)
        }
        player = nil
        engine = nil
        hasTap = false
        routedDeviceUID = nil
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
    )!

    private func makeBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                samples[index] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        return buffer
    }
}
