import RxCodeCore
import SwiftUI

struct MobileThreadLoadingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                content(phase: 0)
            } else {
                TimelineView(.animation) { timeline in
                    content(phase: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
    }

    @ViewBuilder
    private func content(phase: TimeInterval) -> some View {
        GeometryReader { proxy in
            let maxWidth = min(proxy.size.width - 32, 420)
            let topGap = max(22, proxy.size.height * 0.08)

            VStack(spacing: 0) {
                MobileThreadLoadingStatusChip(phase: phase, reduceMotion: reduceMotion)
                    .padding(.top, 18)

                Spacer()
                    .frame(height: topGap)

                MobileThreadLoadingMessageStack(
                    maxWidth: maxWidth,
                    phase: phase,
                    reduceMotion: reduceMotion
                )

                Spacer(minLength: 26)

                MobileThreadLoadingComposerBar(
                    maxWidth: maxWidth,
                    phase: phase,
                    reduceMotion: reduceMotion
                )
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
        }
        .background(.regularMaterial)
    }
}

private struct MobileThreadLoadingStatusChip: View {
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            MobileThreadLoadingGlyph(phase: phase, reduceMotion: reduceMotion)
            Text("Loading thread")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct MobileThreadLoadingGlyph: View {
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        let rotation = Angle.degrees(reduceMotion ? 0 : phase * 220)
        let pulse = reduceMotion ? CGFloat(1) : CGFloat(0.9 + 0.1 * sin(phase * 3.2))

        ZStack {
            Circle()
                .fill(ClaudeTheme.accent.opacity(0.12))
                .scaleEffect(pulse)

            Circle()
                .trim(from: 0.15, to: 0.72)
                .stroke(
                    LinearGradient(
                        colors: [
                            ClaudeTheme.accent,
                            Color.blue.opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(rotation)

            Image(systemName: "text.bubble.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ClaudeTheme.accent)
        }
        .frame(width: 24, height: 24)
    }
}

private struct MobileThreadLoadingMessageStack: View {
    let maxWidth: CGFloat
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 16) {
            MobileThreadLoadingMessageBubble(
                width: maxWidth * 0.86,
                alignment: .leading,
                rows: [0.62, 0.94, 0.72],
                phase: phase,
                reduceMotion: reduceMotion
            )
            MobileThreadLoadingMessageBubble(
                width: maxWidth * 0.64,
                alignment: .trailing,
                rows: [0.88, 0.52],
                phase: phase + 0.22,
                reduceMotion: reduceMotion
            )
            MobileThreadLoadingMessageBubble(
                width: maxWidth * 0.9,
                alignment: .leading,
                rows: [0.46, 0.98, 0.82, 0.58],
                phase: phase + 0.44,
                reduceMotion: reduceMotion
            )
        }
        .frame(width: maxWidth)
    }
}

private struct MobileThreadLoadingMessageBubble: View {
    let width: CGFloat
    let alignment: Alignment
    let rows: [CGFloat]
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                MobileThreadLoadingLine(
                    widthRatio: rows[index],
                    phase: phase + Double(index) * 0.08,
                    reduceMotion: reduceMotion
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct MobileThreadLoadingComposerBar: View {
    let maxWidth: CGFloat
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            MobileThreadLoadingLine(
                widthRatio: 0.72,
                height: 14,
                phase: phase + 0.65,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Circle()
                .fill(ClaudeTheme.accent.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ClaudeTheme.accent.opacity(0.7))
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: maxWidth)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct MobileThreadLoadingLine: View {
    let widthRatio: CGFloat
    var height: CGFloat = 10
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Color.primary.opacity(0.085))
                .overlay {
                    if !reduceMotion {
                        GeometryReader { lineProxy in
                            let cycle = phase.truncatingRemainder(dividingBy: 1.45) / 1.45
                            let travel = CGFloat(cycle) * (lineProxy.size.width + 100) - 70

                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.32),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 70)
                            .offset(x: travel)
                        }
                        .mask(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
                    }
                }
                .frame(width: proxy.size.width * widthRatio, height: height)
        }
        .frame(height: height)
    }
}
