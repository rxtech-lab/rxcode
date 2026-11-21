#if os(macOS)
import SwiftUI
import Combine
import RxCodeCore

// MARK: - Streaming Message (isolated view — chatBridge.messages dependency confined to this view)

struct StreamingMessageView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    var onStructureChanged: () -> Void

    var body: some View {
        let messages = chatBridge.messages
        let activeMessages = activeResponseMessages(from: messages)
        Group {
            // Group the entire response so completed and streaming tool calls share
            // one disclosure while text and interactive cards remain separate.
            ForEach(chatMessageGroups(activeMessages, minGroupSize: 1)) { group in
                if group.isTransientGroup {
                    ChatTransientGroupSummaryView(messages: group.messages)
                        .id(group.id)
                        .transition(streamFadeTransition(role: .assistant))
                } else if let message = group.messages.first {
                    ChatMessageBubble(message: message)
                        .id(message.id)
                        .transition(streamFadeTransition(role: message.role))
                }
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.05), value: activeMessages.map(\.id))
        .onChange(of: messages.count) { _, _ in
            onStructureChanged()
        }
    }

    private func streamFadeTransition(role: Role) -> AnyTransition {
        let anchor: UnitPoint = role == .user ? .bottomTrailing : .bottomLeading
        let insertion: AnyTransition = .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
            .animation(.spring(duration: 0.22, bounce: 0.08))
        return .asymmetric(insertion: insertion, removal: .identity)
    }

    /// Returns the last consecutive assistant sequence (including streaming turn) while streaming.
    /// Returns an empty array when not streaming so StreamingMessageView renders nothing.
    private func activeResponseMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.last?.isStreaming == true else { return [] }
        return chatSuppressPlanReadyFollowups(in: Array(messages[chatStreamingBoundaryIndex(in: messages)...]))
    }
}

// MARK: - Empty Session

struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: ClaudeTheme.size(36)))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Text("How can I help you?", bundle: .module)
                .font(.system(size: ClaudeTheme.size(18), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Streaming Indicator

struct StreamingIndicatorView: View {
    let isThinking: Bool
    var startDate: Date?
    var agentProvider: AgentProvider = .claudeCode
    var outputTokens: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isThinking {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text(thinkingLabel)
                        .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .tint(ClaudeTheme.textTertiary)
                }
            }

            HStack(spacing: 10) {
                AnimatedDotsView()
                metadataView
            }
        }
        .padding(.vertical, 8)
        .accessibilityLabel(isThinking ? "\(thinkingLabel) in progress" : "Response in progress")
    }

    private var thinkingLabel: String {
        agentProvider == .codex ? "reasoning" : "thinking"
    }

    private var metadataView: some View {
        HStack(spacing: 6) {
            if let startDate {
                InlineElapsedTimeView(startDate: startDate)
            }

            if outputTokens > 0 {
                if startDate != nil {
                    separator
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                    Text(formatTokenCount(outputTokens))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(outputTokens)))
                    Text("tok", bundle: .module)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .animation(.easeInOut(duration: 0.25), value: outputTokens)
            }
        }
        .font(.system(size: ClaudeTheme.size(11), weight: .medium, design: .monospaced))
        .foregroundStyle(ClaudeTheme.textSecondary)
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(ClaudeTheme.textTertiary)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 10_000 {
            return "\(count / 1000)k"
        }
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

/// Compact elapsed-time readout that lives inside the streaming indicator pill.
/// Uses `mm:ss` for under an hour and falls back to `Xh Ym` for longer runs.
private struct InlineElapsedTimeView: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(format(elapsed))
            .monospacedDigit()
            .onAppear { elapsed = Date().timeIntervalSince(startDate) }
            .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(startDate) }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 3600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return String(format: "%dh %dm", total / 3600, (total % 3600) / 60)
    }
}

/// Three bouncing dots — the entire "generating response" indicator.
/// Replaces the previous card with "Thinking..." / "Generating response..." text.
struct AnimatedDotsView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.22, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(ClaudeTheme.textTertiary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.35)
                    .scaleEffect(phase == i ? 1.0 : 0.8)
                    .animation(.spring(duration: 0.3, bounce: 0.2), value: phase)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Elapsed Time

struct ElapsedTimeView: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(elapsed.formattedDuration)
            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
            }
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startDate)
            }
    }
}
#endif
