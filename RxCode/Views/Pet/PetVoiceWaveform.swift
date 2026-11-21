import RxCodeCore
import SwiftUI

// MARK: - Level Smoothing

/// Debounces raw audio meter readings so the UI does not flicker.
/// Rises quickly when sound starts, falls slowly afterwards, and ignores
/// low-level noise.
final class PetVoiceLevelSmoother {
    private(set) var samples: [CGFloat]
    private(set) var smoothed: CGFloat = 0
    private var lastSampleAt: Date?
    private var lastPushAt: Date?

    let capacity: Int
    let pushInterval: TimeInterval
    let noiseGate: CGFloat
    let attack: CGFloat
    let release: CGFloat

    init(capacity: Int = 48, pushInterval: TimeInterval = 1.0 / 24.0, noiseGate: CGFloat = 0.015,
         attack: CGFloat = 0.55, release: CGFloat = 0.12) {
        self.capacity = capacity
        self.pushInterval = pushInterval
        self.noiseGate = noiseGate
        self.attack = attack
        self.release = release
        samples = Array(repeating: 0, count: capacity)
    }

    /// Maps a raw meter value to 0...1 on a perceptual curve.
    static func normalized(_ raw: Float) -> CGFloat {
        let value = CGFloat(max(0, min(1, raw)))
        return min(1, sqrt(value) * 1.35)
    }

    /// Feeds the latest reading. Returns `true` when a new bar was added.
    @discardableResult
    func advance(to date: Date, raw: Float) -> Bool {
        let target = Self.normalized(raw)
        let gated = target < noiseGate ? 0 : target

        // Adjust the smoothing step for the actual frame time so it behaves the same at any refresh rate.
        let elapsed = lastSampleAt.map { max(0, min(0.25, date.timeIntervalSince($0))) } ?? (1.0 / 60.0)
        lastSampleAt = date
        let frames = CGFloat(elapsed * 60)
        let coefficient = gated > smoothed ? attack : release
        let step = 1 - pow(1 - coefficient, max(frames, 0.01))
        smoothed += (gated - smoothed) * step
        if smoothed < 0.002 { smoothed = 0 }

        guard date.timeIntervalSince(lastPushAt ?? .distantPast) >= pushInterval else { return false }
        lastPushAt = date
        samples.removeFirst()
        samples.append(smoothed)
        return true
    }
}

// MARK: - Waveform

/// A scrolling, mirrored bar waveform that follows a live audio level.
struct PetVoiceWaveform: View {
    var level: Float
    var tint: Color
    var isEnabled: Bool = true
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    var minimumBarHeight: CGFloat = 2

    @State private var smoother = PetVoiceLevelSmoother(capacity: 96)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isEnabled)) { context in
            Canvas { graphics, size in
                smoother.advance(to: context.date, raw: isEnabled ? level : 0)
                draw(in: &graphics, size: size, date: context.date)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int((PetVoiceLevelSmoother.normalized(level) * 100).rounded())) percent")
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, date: Date) {
        let pitch = barWidth + barSpacing
        let count = max(1, min(smoother.capacity, Int((size.width + barSpacing) / pitch)))
        let samples = smoother.samples.suffix(count)
        let midY = size.height / 2
        let usable = max(0, size.height - minimumBarHeight)
        let startX = size.width - CGFloat(count) * pitch + barSpacing
        let idlePhase = date.timeIntervalSinceReferenceDate * 2.4

        for (offset, sample) in samples.enumerated() {
            let position = CGFloat(offset) / CGFloat(max(1, count - 1))
            // Fade older bars on the left edge.
            let fade = 0.25 + 0.75 * position
            // Small idle movement so the waveform still looks live when quiet.
            let idle = isEnabled ? (sin(idlePhase + Double(offset) * 0.45) + 1) * 0.5 * 1.5 : 0
            let height = minimumBarHeight + CGFloat(idle) + (isEnabled ? usable * sample : 0)
            let rect = CGRect(x: startX + CGFloat(offset) * pitch, y: midY - height / 2,
                              width: barWidth, height: height)
            let color = isEnabled ? tint.opacity(fade * (0.45 + 0.55 * Double(sample))) : Color.secondary.opacity(0.25)
            graphics.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }
    }
}

// MARK: - Mic Orb

/// A circular mic badge with a pulsing ring that follows the input level.
struct PetMicLevelOrb: View {
    var level: Float
    var isMuted: Bool
    var tint: Color
    var diameter: CGFloat = 64

    @State private var smoother = PetVoiceLevelSmoother(capacity: 2)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isMuted)) { context in
            let _ = smoother.advance(to: context.date, raw: isMuted ? 0 : level)
            let amount = isMuted ? 0 : smoother.smoothed
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10 + 0.10 * amount))
                    .scaleEffect(1 + 0.45 * amount)
                Circle()
                    .strokeBorder(tint.opacity(0.25 + 0.5 * amount), lineWidth: 1.5)
                    .scaleEffect(1 + 0.22 * amount)
                Circle()
                    .fill(isMuted ? Color.secondary.opacity(0.18) : tint.opacity(0.22))
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundStyle(isMuted ? ClaudeTheme.textSecondary : tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter * 1.5, height: diameter * 1.5)
        .accessibilityHidden(true)
    }
}

// MARK: - Tap Debounce

/// Ignores repeated presses within a short window so rapid clicks do not
/// toggle voice or mute several times.
@MainActor
final class PetTapDebouncer {
    private var lastFire: [String: Date] = [:]
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.4) {
        self.interval = interval
    }

    func run(_ key: String, _ action: () -> Void) {
        let now = Date()
        if let last = lastFire[key], now.timeIntervalSince(last) < interval { return }
        lastFire[key] = now
        action()
    }
}
