import AVFoundation
import Foundation
import Observation

/// A small render-thread mailbox. Only the sprite reads it; audio never invalidates the panel.
nonisolated final class PetSpeechEnvelope: @unchecked Sendable {
    struct Point: Sendable { let time: TimeInterval; let level: Float }
    private let lock = NSLock()
    private var points: [Point] = []
    private var enabled = false
    private var mouthOpen = false
    private var mouthChangedAt: TimeInterval = -.infinity

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        points.removeAll(keepingCapacity: true)
        mouthOpen = false
        mouthChangedAt = -.infinity
        lock.unlock()
    }

    func append(_ values: [Point]) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        points.append(contentsOf: values)
        if points.count > 128 { points.removeFirst(points.count - 128) }
    }

    func level(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, let point = points.last(where: { $0.time <= time }),
              time - point.time < 0.15 else { return 0 }
        return point.level
    }

    /// Hold through brief syllable gaps and keep each sprite visible long enough
    /// to avoid rapid chatter. Mute and cancellation bypass the hold immediately.
    func isMouthOpen(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        let threshold: Float = mouthOpen ? 0.08 : 0.12
        let hasSpeech = points.contains { $0.time <= time && time - $0.time < 0.14 && $0.level > threshold }
        let minimumDuration = mouthOpen ? 0.18 : 0.12
        if hasSpeech != mouthOpen, time - mouthChangedAt >= minimumDuration {
            mouthOpen = hasSpeech
            mouthChangedAt = time
        }
        return mouthOpen
    }

    /// Runs on the audio callback, in 20 ms windows, after synthesis and queuing.
    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, latency: TimeInterval) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        let count = Int(buffer.frameLength)
        let window = max(1, Int(rate * 0.02))
        let start = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : ProcessInfo.processInfo.systemUptime
        var values: [Point] = []
        for offset in stride(from: 0, to: count, by: window) {
            let end = min(count, offset + window)
            var energy: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for i in offset..<end { energy += channels[channel][i] * channels[channel][i] }
            }
            let rms = sqrt(energy / Float((end - offset) * Int(buffer.format.channelCount)))
            values.append(Point(time: start + latency + Double(offset) / rate,
                                level: Self.openness(rms: rms)))
        }
        append(values)
    }

    static func openness(rms: Float) -> Float {
        guard rms.isFinite, rms > 0.008 else { return 0 }
        return min(1, sqrt(max(0, rms - 0.008) * 5))
    }
}

@MainActor @Observable
final class PetSpeechPlaybackSignal {
    private(set) var isActive = false
    private var isSuppressed = false
    nonisolated let envelope = PetSpeechEnvelope()

    func begin() {
        guard !isActive, !isSuppressed else { return }
        envelope.setEnabled(true)
        isActive = true
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        if suppressed { reset() }
    }

    func reset() {
        envelope.setEnabled(false)
        isActive = false
    }

    /// WebRTC supplies remote audio energy rather than exposing its speaker's PCM.
    func updateRemoteLevel(_ level: Float) {
        guard level.isFinite, level > 0 else { reset(); return }
        begin()
        envelope.append([.init(time: ProcessInfo.processInfo.systemUptime,
                               level: level.isFinite ? max(0, min(1, level)) : 0)])
    }
}

/// RTP audioLevel can retain its last nonzero value during packet gaps. Energy deltas
/// make those gaps silent instead of holding a mouth open indefinitely.
nonisolated struct PetRemoteSpeechEnergy {
    private var previous: [String: (energy: Double, duration: Double)] = [:]

    mutating func level(id: String, energy: Double?, duration: Double?) -> Double {
        guard let energy, let duration else { return 0 }
        let old = previous.updateValue((energy, duration), forKey: id)
        guard let old, duration > old.duration, energy >= old.energy else { return 0 }
        let rms = sqrt(max(0, (energy - old.energy) / (duration - old.duration)))
        return rms.isFinite ? rms : 0
    }
}
