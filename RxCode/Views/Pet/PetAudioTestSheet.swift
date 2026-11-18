import AppKit
import RxAgentVoice
import RxCodeCore
import SwiftUI

enum PetAudioTest: String, Identifiable {
    case microphone, speaker
    var id: Self { self }
}

struct PetAudioTestSheet: View {
    let test: PetAudioTest
    let configuration: PetConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var meters = VoiceMeters()
    @State private var sound: NSSound?
    @State private var status = "Starting…"
    @State private var lastHeardAt: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if test == .microphone {
                    microphoneMeter
                } else {
                    Text(status)
                    Button("Play Test Sound", action: playSound)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(test == .microphone ? "Test Microphone" : "Test Speaker")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .task {
            guard test == .microphone else {
                playSound()
                return
            }
            let driver = PetVoiceAudioDriver(meters: meters, inputDeviceUID: configuration.microphoneDeviceUID,
                                             outputDeviceUID: configuration.speakerDeviceUID)
            defer { driver.stop() }
            do {
                driver.setCaptureEnabled(true)
                let stream = try await driver.start(format: VoicePCMFormat(sampleRate: 24_000, channels: 1))
                status = "Speak into the microphone to check its input level."
                for await _ in stream {
                    try Task.checkCancellation()
                }
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
        .onDisappear { sound?.stop() }
    }

    private var microphoneMeter: some View {
        VStack(spacing: 14) {
            PetMicLevelOrb(level: meters.input, isMuted: false, tint: ClaudeTheme.accent, diameter: 56)

            PetVoiceWaveform(level: meters.input, tint: ClaudeTheme.accent, barWidth: 4, barSpacing: 3)
                .frame(height: 56)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ClaudeTheme.surfaceSecondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Microphone input level")

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                // Debounced: stays on for a moment after speech so it does not flicker between words.
                let hearing = lastHeardAt.map { context.date.timeIntervalSince($0) < 0.8 } ?? false
                Label(hearing ? "Hearing you" : "Waiting for sound",
                      systemImage: hearing ? "checkmark.circle.fill" : "ear")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    .foregroundStyle(hearing ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.2), value: hearing)
            }

            Text(status)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .onChange(of: meters.input) { _, raw in
            guard PetVoiceLevelSmoother.normalized(raw) > 0.12 else { return }
            let now = Date()
            if lastHeardAt.map({ now.timeIntervalSince($0) > 0.1 }) ?? true { lastHeardAt = now }
        }
    }

    private func playSound() {
        sound?.stop()
        sound = NSSound(named: "Glass")?.copy() as? NSSound
        sound?.playbackDeviceIdentifier = configuration.speakerDeviceUID.flatMap {
            PetAudioDevices.deviceID(forUID: $0) == nil ? nil : $0
        }
        status = sound?.play() == true ? "Listen for the chime on your selected speaker." : "The test sound could not play."
    }
}
