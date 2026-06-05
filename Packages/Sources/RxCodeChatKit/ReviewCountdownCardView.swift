import RxCodeCore
import SwiftUI

/// Interactive card shown while a code review is debounced before it starts:
///
///     Code review will start in 47 seconds
///     [ Stop Review ]   [ Start it now ]
///
/// Rendered by `ToolResultView` whenever it sees a `ToolCall` named
/// `ReviewCountdownCard.toolName`. While counting (`toolCall.result == nil`) it
/// ticks a live countdown and shows the two buttons; once the review is started
/// or cancelled the hook fills in `toolCall.result` and this collapses to a
/// static one-line summary with a status badge.
///
/// The buttons route through `windowState.reviewCountdownHandler`. The desktop
/// installs that handler; mobile does not, so the card is read-only there (it
/// still shows the live countdown, just without the buttons).
struct ReviewCountdownCardView: View {
    let toolCall: ToolCall

    @Environment(WindowState.self) private var windowState
    @State private var now: Date = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var parentSessionKey: String {
        toolCall.input[ReviewCountdownCard.parentSessionKey]?.stringValue ?? ""
    }

    private var startAt: Date? {
        guard let seconds = toolCall.input[ReviewCountdownCard.startAtKey]?.numberValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whole seconds left before the review auto-starts (never negative).
    private var remainingSeconds: Int {
        guard let startAt else { return 0 }
        return max(0, Int(startAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Still counting down until the hook fills in a result.
    private var isCounting: Bool { toolCall.result == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)
                    .frame(width: 16, height: 16)

                headline
                    .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer()

                statusBadge
            }

            if isCounting, let handler = windowState.reviewCountdownHandler {
                HStack(spacing: 8) {
                    Button {
                        handler(parentSessionKey, .stop)
                    } label: {
                        Text("Stop Review")
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        handler(parentSessionKey, .startNow)
                    } label: {
                        Text("Start it now")
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .bubbleStyle(.tool)
        .padding(.vertical, 6)
        .onReceive(timer) { now = $0 }
    }

    private var headline: Text {
        if isCounting {
            let unit = remainingSeconds == 1 ? "second" : "seconds"
            return Text("Code review will start in \(remainingSeconds) \(unit)")
        }
        // Finalized: the hook wrote a short summary into the result.
        return Text(verbatim: toolCall.result ?? "")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isCounting {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Waiting to start review")
        } else if toolCall.isError {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(ClaudeTheme.textTertiary)
                .font(.caption)
                .accessibilityLabel("Review cancelled")
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusSuccess)
                .font(.caption)
                .accessibilityLabel("Review started")
        }
    }
}
