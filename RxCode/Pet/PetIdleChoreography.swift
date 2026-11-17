import Foundation
import os

/// One displayed frame of the ambient idle routine.
nonisolated struct PetIdleStep: Equatable, Sendable {
    let motion: PetMotion
    let column: Int
    let duration: TimeInterval
}

/// Builds varied, pet-like idle "bouts" from the sprite rows: play a pose, loop its last
/// few frames, rock back and forth, pause for a beat, settle back, then pick another pose.
nonisolated enum PetIdleChoreographer {
    static let candidateMotions: [PetMotion] = [.idle, .waving, .resting, .waiting]

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// - Parameter rows: Per-frame durations for each pose row the character can show.
    static func bout(
        seed: UInt64,
        index: UInt64,
        sleepy: Bool,
        rows: [PetMotion: [TimeInterval]],
        previous: PetMotion? = nil
    ) -> [PetIdleStep] {
        var rng = SeededGenerator(state: seed &+ index &* 0x2545_F491_4F6C_DD1D)
        let weights: [(PetMotion, Int)] = sleepy
            ? [(.resting, 5), (.idle, 1)]
            : [(.idle, 3), (.waving, 2), (.resting, 2), (.waiting, 2)]
        var available = weights.filter { rows[$0.0]?.isEmpty == false }
        // Avoid repeating the same pose twice in a row when there is a choice.
        if available.count > 1 { available.removeAll { $0.0 == previous } }
        guard !available.isEmpty else { return [] }

        let motion = pick(available, using: &rng)
        let durations = rows[motion] ?? []
        let count = durations.count
        let speed = sleepy ? Double.random(in: 1.3...1.8, using: &rng) : Double.random(in: 0.85...1.2, using: &rng)
        var steps: [PetIdleStep] = []

        func frame(_ column: Int, scale: Double = 1) {
            steps.append(PetIdleStep(motion: motion, column: column, duration: max(0.04, durations[column] * speed * scale)))
        }
        func forward(_ range: Range<Int>, scale: Double = 1) { range.forEach { frame($0, scale: scale) } }
        func backward(_ range: Range<Int>, scale: Double = 1) { range.reversed().forEach { frame($0, scale: scale) } }
        func hold(_ column: Int, _ seconds: ClosedRange<Double>) {
            steps.append(PetIdleStep(motion: motion, column: column, duration: Double.random(in: seconds, using: &rng)))
        }

        guard count > 1 else {
            hold(0, sleepy ? 2...4 : 1...2.5)
            return steps
        }

        let last = count - 1
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            // Play through, then loop the tail (tail wag, blink, keep waving).
            forward(0..<count)
            let tail = min(last, Int.random(in: 3...6, using: &rng))
            for _ in 0..<Int.random(in: 2...4, using: &rng) { forward((count - tail)..<count) }
        case 1:
            // Play through, then rock back and forth over the last few frames.
            forward(0..<count)
            let lower = max(0, count - Int.random(in: 4...8, using: &rng))
            for _ in 0..<Int.random(in: 2...3, using: &rng) {
                backward(lower..<last)
                forward((lower + 1)..<count)
            }
        case 2:
            // Ping-pong the whole pose.
            for _ in 0..<Int.random(in: 1...2, using: &rng) {
                forward(0..<count)
                backward(1..<last)
            }
            forward(0..<count)
        default:
            // Double take: play, pause, play again.
            forward(0..<count)
            hold(last, 0.4...1.0)
            forward(0..<count, scale: 0.9)
        }

        // Pause on the final pose, then settle back to the neutral first frame.
        hold(last, sleepy ? 1.5...3.5 : 0.5...1.8)
        backward(0..<last, scale: 0.6)
        hold(0, sleepy ? 1.8...4.0 : 0.6...2.2)
        return steps
    }

    private static func pick(_ weights: [(PetMotion, Int)], using rng: inout SeededGenerator) -> PetMotion {
        var roll = Int.random(in: 0..<weights.reduce(0) { $0 + $1.1 }, using: &rng)
        for (motion, weight) in weights {
            if roll < weight { return motion }
            roll -= weight
        }
        return weights[0].0
    }
}

/// Lazily extends the idle routine bout by bout so the timeline can look up the frame for any elapsed time.
@MainActor
final class PetIdleScript {
    private var key = ""
    private var steps: [PetIdleStep] = []
    private var cursor = 0
    private var cursorStart: TimeInterval = 0
    private var boutIndex: UInt64 = 0
    private var seed = UInt64.random(in: .min ... .max)
    private var lastLoggedSecond = -1

    func step(at elapsed: TimeInterval, key: String, sleepy: Bool,
              rows: () -> [PetMotion: [TimeInterval]]) -> PetIdleStep? {
        if key != self.key || elapsed < cursorStart {
            self.key = key
            steps = []
            cursor = 0
            cursorStart = elapsed
            boutIndex = 0
            seed = .random(in: .min ... .max)
            lastLoggedSecond = -1
            petAnimationLogger.debug("idle script reset key=\(key, privacy: .public) sleepy=\(sleepy) elapsed=\(elapsed)")
        }
        // After a long pause (screen asleep, timeline suspended) resume from now instead of fast-forwarding.
        if elapsed - cursorStart > 60 { cursorStart = elapsed }

        var cachedRows: [PetMotion: [TimeInterval]]?
        func extend() -> Bool {
            let resolved = cachedRows ?? rows()
            cachedRows = resolved
            let bout = PetIdleChoreographer.bout(seed: seed, index: boutIndex, sleepy: sleepy,
                                                 rows: resolved, previous: steps.last?.motion)
            if bout.isEmpty {
                petAnimationLogger.error("idle bout #\(self.boutIndex) empty; rows=\(resolved.mapValues(\.count).description, privacy: .public)")
            } else {
                let total = bout.reduce(0) { $0 + $1.duration }
                petAnimationLogger.debug("idle bout #\(self.boutIndex) motion=\(bout[0].motion.rawValue, privacy: .public) steps=\(bout.count) duration=\(total, format: .fixed(precision: 2))s")
            }
            boutIndex &+= 1
            steps.append(contentsOf: bout)
            return !bout.isEmpty
        }

        if cursor >= steps.count, !extend() { return nil }
        while elapsed >= cursorStart + steps[cursor].duration {
            cursorStart += steps[cursor].duration
            cursor += 1
            if cursor >= steps.count, !extend() { return nil }
        }
        if cursor > 512 {
            steps.removeFirst(cursor)
            cursor = 0
        }
        let current = steps[cursor]
        // Heartbeat proves the TimelineView keeps ticking; silence here means the view stopped redrawing.
        if Int(elapsed) != lastLoggedSecond {
            lastLoggedSecond = Int(elapsed)
            petAnimationLogger.debug("idle tick t=\(elapsed, format: .fixed(precision: 2)) motion=\(current.motion.rawValue, privacy: .public) col=\(current.column)")
        }
        return current
    }
}
