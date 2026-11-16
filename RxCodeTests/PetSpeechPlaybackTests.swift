import AVFoundation
import Foundation
import Testing
@testable import RxCode

struct PetSpeechPlaybackTests {

    @Test("Speech envelope follows playback time, silence, expiry, and cancellation")
    func speechEnvelopeTiming() throws {
        let envelope = PetSpeechEnvelope()
        envelope.setEnabled(true)
        envelope.append([.init(time: 10, level: 0.7), .init(time: 10.04, level: 0)])
        #expect(envelope.level(at: 9.99) == 0)
        #expect(envelope.level(at: 10.02) == 0.7)
        #expect(envelope.level(at: 10.05) == 0)
        envelope.append([.init(time: 11, level: 0.8)])
        #expect(envelope.level(at: 11.2) == 0)
        envelope.setEnabled(false)
        envelope.append([.init(time: 12, level: 1)])
        #expect(envelope.level(at: 12) == 0)
        envelope.setEnabled(true)
        #expect(envelope.level(at: 12) == 0)
        #expect(PetSpeechEnvelope.openness(rms: 0.001) == 0)
        #expect(PetSpeechEnvelope.openness(rms: .nan) == 0)
        #expect(PetSpeechEnvelope.openness(rms: 0.1) > PetSpeechEnvelope.openness(rms: 0.02))
    }

    @Test("Speech mouth holds syllables, limits transitions, and closes immediately on reset")
    func speechMouthDebounce() {
        let envelope = PetSpeechEnvelope()
        envelope.setEnabled(true)
        envelope.append([.init(time: 10, level: 0.7), .init(time: 10.02, level: 0)])
        #expect(envelope.isMouthOpen(at: 10))
        #expect(envelope.isMouthOpen(at: 10.10))
        #expect(envelope.isMouthOpen(at: 10.17))
        #expect(!envelope.isMouthOpen(at: 10.19))
        envelope.append([.init(time: 10.20, level: 0.7)])
        #expect(!envelope.isMouthOpen(at: 10.21))
        #expect(envelope.isMouthOpen(at: 10.32))
        envelope.append([.init(time: 10.45, level: 0.1)])
        #expect(envelope.isMouthOpen(at: 10.52))
        #expect(!envelope.isMouthOpen(at: 10.60))
        envelope.append([.init(time: 11, level: 0.7)])
        #expect(envelope.isMouthOpen(at: 11))
        envelope.setEnabled(false)
        #expect(!envelope.isMouthOpen(at: 11.01))
        envelope.setEnabled(true)
        #expect(!envelope.isMouthOpen(at: 11.02))
    }

    @Test("Rendered PCM uses twenty millisecond windows rather than a whole queued utterance")
    func speechPCMEnvelope() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1440))
        buffer.frameLength = 1440
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<1440 { samples[i] = i < 480 ? 0 : (i < 960 ? 0.15 : 0) }
        let envelope = PetSpeechEnvelope()
        envelope.setEnabled(true)
        let host = AVAudioTime.hostTime(forSeconds: 10)
        envelope.consume(buffer, at: AVAudioTime(hostTime: host), latency: 0.1)
        #expect(envelope.level(at: 10.09) == 0)
        #expect(envelope.level(at: 10.11) == 0)
        #expect(envelope.level(at: 10.13) > 0.5)
        #expect(envelope.level(at: 10.15) == 0)
    }

    @Test("Speech mouth resets on mute and ignores stale output while suppressed")
    @MainActor
    func speechMouthLifecycle() {
        let signal = PetSpeechPlaybackSignal()
        signal.updateRemoteLevel(0.8)
        #expect(signal.isActive)
        #expect(signal.envelope.level() == 0.8)
        signal.setSuppressed(true)
        signal.updateRemoteLevel(0.9)
        #expect(!signal.isActive)
        #expect(signal.envelope.level() == 0)
        signal.setSuppressed(false)
        signal.updateRemoteLevel(0.6)
        #expect(signal.envelope.level() == 0.6)
        signal.reset()
        #expect(signal.envelope.level() == 0)
        #expect(!signal.isActive)
    }

    @Test("Remote speech energy does not hold a stale RTP audio level through pauses")
    func remoteSpeechEnergy() {
        var energy = PetRemoteSpeechEnergy()
        #expect(energy.level(id: "audio", energy: 1, duration: 1) == 0)
        #expect(energy.level(id: "audio", energy: 1.04, duration: 2) > 0)
        #expect(energy.level(id: "audio", energy: 1.04, duration: 2) == 0)
        #expect(energy.level(id: "audio", energy: 1.04, duration: 3) == 0)
        #expect(energy.level(id: "audio", energy: nil, duration: nil) == 0)
    }

    @Test("Each robot pose has a mouth within its original sprite bounds")
    @MainActor
    func speechMouthArtwork() throws {
        let atlas = try #require(PetSpriteCache.shared.atlas(for: .rxcodeBuddy))
        #expect(atlas.manifest.frames.count == 192)
        for frame in atlas.manifest.frames {
            let mouth = try #require(frame.mouth)
            #expect(mouth.x >= 0 && mouth.y >= 0)
            #expect(mouth.x + mouth.width <= Double(frame.width))
            #expect(mouth.y + mouth.height <= Double(frame.height))
        }
    }
}
