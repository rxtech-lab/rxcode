import SwiftUI
import RxCodeCore

/// Minimal iOS message bubble. Intentionally simpler than the desktop's
/// `MessageBubble`: just text + tool-call summaries, no markdown highlighting
/// or rich diffs. The mobile companion is a glance-and-respond view; deep
/// inspection still lives on the desktop.
struct MobileMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(12)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock) -> some View {
        if let text = block.text, !text.isEmpty {
            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(textColor)
        } else if let tool = block.toolCall {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                    Text(tool.name)
                        .font(.caption.monospaced())
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.secondary)
                if let result = tool.result, !result.isEmpty {
                    Text(result)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        }
    }

    private var bubbleBackground: Color {
        message.role == .user ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12)
    }

    private var textColor: Color {
        message.role == .user ? .primary : .primary
    }
}
