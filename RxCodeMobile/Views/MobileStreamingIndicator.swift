import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Streaming Indicator

/// Loading indicator shown at the end of the message list while the agent is
/// generating a response — mirrors the desktop `StreamingIndicatorView`. Shows
/// a "Thinking…" label while the agent is producing reasoning tokens, and three
/// bouncing dots throughout.
struct MobileStreamingIndicator: View {
    var isThinking: Bool = false
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

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
            dots
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityLabel(isThinking ? "Thinking" : "Response in progress")
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(ClaudeTheme.textTertiary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .scaleEffect(phase == i ? 1.0 : 0.85)
                    .animation(.easeInOut(duration: 0.25), value: phase)
            }
        }
    }
}
