import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// "5 / 6  ▰▰▰▨▱  83%" — rolled-up story progress. Finished children fill the
/// bar solid; started-but-unfinished children follow as an animated striped
/// "pending" segment in `activeTint`, with a live "N in progress" caption.
struct StoryProgressBar: View {
    let progress: StoryProgress
    var tint: Color = ClaudeTheme.accent
    var activeTint: Color = ClaudeTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(progress.done) / \(progress.total)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .monospacedDigit()

                StoryProgressTrack(progress: progress, tint: tint, activeTint: activeTint)
                    .frame(height: 6)

                Text("\(progress.percent)%")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .monospacedDigit()
            }

            if progress.active > 0 {
                HStack(spacing: 5) {
                    PulsingDot(color: activeTint)
                    Text("\(progress.active) in progress")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(activeTint)
                        .monospacedDigit()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(progress.done) of \(progress.total) tasks done, \(progress.active) in progress"))
    }
}

extension StoryProgressBar {
    /// Colors the bar with the board's own columns: the first done column for
    /// finished work and the first chat column for the pending segment.
    init(story: ProjectStory, board: TaskBoard) {
        self.init(progress: board.progress(for: story), board: board)
    }

    /// Same colors, for a caller that already has the story's progress (from
    /// `TaskBoard.storyRollups()`).
    init(progress: StoryProgress, board: TaskBoard) {
        self.init(
            progress: progress,
            tint: board.effectiveColumns.first(where: \.countsAsDone)?.tint ?? ClaudeTheme.accent,
            activeTint: board.firstChatColumn?.tint ?? ClaudeTheme.accent
        )
    }
}

/// The bar itself: solid done segment, striped pending segment, then track.
private struct StoryProgressTrack: View {
    let progress: StoryProgress
    let tint: Color
    let activeTint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let doneWidth = width * progress.fraction
            let activeWidth = width * progress.activeFraction
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))

                if activeWidth > 0 {
                    PendingStripes(color: activeTint)
                        .frame(width: doneWidth + activeWidth)
                        .clipShape(Capsule())
                }

                if doneWidth > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: doneWidth)
                }
            }
        }
    }
}

/// Diagonal barber-pole stripes that drift left to right while work is
/// underway. The motion is a single repeating offset animation, so it stays
/// cheap on boards with many stories; Reduce Motion freezes it.
private struct PendingStripes: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    private let period: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.35)))
                var stripes = Path()
                var x = -height - period
                while x < size.width + period {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + height, y: 0))
                    stripes.addLine(to: CGPoint(x: x + height + period / 2, y: 0))
                    stripes.addLine(to: CGPoint(x: x + period / 2, y: size.height))
                    stripes.closeSubpath()
                    x += period
                }
                context.fill(stripes, with: .color(color.opacity(0.85)))
            }
            .frame(width: proxy.size.width + period * 2)
            .offset(x: phase - period * 2)
        }
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                phase = period
            }
        }
    }
}

/// Small status dot with a soft expanding halo.
private struct PulsingDot: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background(
                Circle()
                    .fill(color.opacity(isPulsing ? 0 : 0.5))
                    .scaleEffect(isPulsing ? 2.4 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
    }
}
