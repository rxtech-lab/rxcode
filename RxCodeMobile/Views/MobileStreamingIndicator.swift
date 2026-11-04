import RxCodeCore
import SwiftUI

// MARK: - Streaming Indicator

/// Loading indicator shown at the end of the message list while the agent is
/// generating a response — mirrors the desktop `StreamingIndicatorView`. Shows
/// a "Thinking…" label while the agent is producing reasoning tokens, and three
/// bouncing dots throughout.
struct MobileStreamingIndicator: View {
    var isThinking: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isThinking {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Thinking")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .transition(.opacity)
            }
            MobileStreamingDots()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .accessibilityLabel(isThinking ? "Thinking" : "Response in progress")
    }
}

/// Animate fixed-size dots without a timer publishing state changes into a
/// self-sizing collection cell on every beat.
private struct MobileStreamingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPulsing = false

    private var shouldAnimate: Bool { !reduceMotion && scenePhase == .active }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(ClaudeTheme.textTertiary)
                    .frame(width: 7, height: 7)
                    .opacity(isPulsing ? 1 : 0.35)
                    .scaleEffect(isPulsing ? 1 : 0.85)
                    .animation(
                        shouldAnimate
                            ? .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15)
                            : nil,
                        value: isPulsing
                    )
            }
        }
        .frame(width: 31, height: 7)
        .accessibilityHidden(true)
        .onAppear { isPulsing = shouldAnimate }
        .onChange(of: shouldAnimate) { _, active in isPulsing = active }
        .onDisappear { isPulsing = false }
    }
}
