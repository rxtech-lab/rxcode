import SwiftUI
import RxCodeCore

public struct ChatMessageBubble: View {
    let message: ChatMessage

    public init(message: ChatMessage) {
        self.message = message
    }

    public var body: some View {
        #if os(macOS)
        MessageBubble(message: message)
        #else
        CompactChatMessageBubble(message: message)
        #endif
    }
}

#if !os(macOS)
private struct CompactChatMessageBubble: View {
    let message: ChatMessage

    private enum RenderBlock: Identifiable {
        case text(MessageBlock)
        case tool(ToolCall)
        case transientTools(id: String, tools: [ToolCall])

        var id: String {
            switch self {
            case .text(let block):
                return block.id
            case .tool(let toolCall):
                return toolCall.id
            case .transientTools(let id, _):
                return id
            }
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if message.role == .user {
                    let displayed = ChatSession.extractDisplayedContent(from: message.content)
                    if !displayed.text.isEmpty {
                        userTextBubble(displayed.text)
                    }
                } else if message.isCompactBoundary {
                    compactBoundaryBubble
                } else if message.isError {
                    errorBubble
                } else {
                    ForEach(renderBlocks) { block in
                        blockView(block)
                    }

                    if !message.isStreaming, let duration = message.duration {
                        HStack(spacing: 4) {
                            if message.isResponseComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: ClaudeTheme.messageSize(11)))
                                    .foregroundStyle(ClaudeTheme.statusSuccess)
                            }
                            Text(duration.formattedDuration)
                                .font(.system(size: ClaudeTheme.messageSize(11), design: .monospaced))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                        }
                    }
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func blockView(_ block: RenderBlock) -> some View {
        switch block {
        case .text(let messageBlock):
            if let text = messageBlock.text, !text.isEmpty {
                assistantText(text)
            }
        case .tool(let toolCall):
            ToolResultView(toolCall: toolCall, isMessageStreaming: message.isStreaming)
        case .transientTools(_, let tools):
            ChatTransientToolSummaryView(tools: tools)
        }
    }

    private func userTextBubble(_ text: String) -> some View {
        ChatTextContentView(
            text,
            size: ClaudeTheme.messageSize(14),
            color: ClaudeTheme.userBubbleText,
            lineSpacing: 2
        )
        .bubbleStyle(.user)
        .frame(maxWidth: 500, alignment: .trailing)
    }

    private func assistantText(_ text: String) -> some View {
        MarkdownContentView(text: text)
            .foregroundStyle(ClaudeTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private var compactBoundaryBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
            ChatTextContentView(
                message.content,
                size: ClaudeTheme.messageSize(13),
                weight: .medium,
                color: ClaudeTheme.textTertiary
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: BubbleStyle.borderWidth)
        )
    }

    private var errorBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: ClaudeTheme.messageSize(13)))
                .foregroundStyle(ClaudeTheme.statusWarning)
            ChatTextContentView(
                message.content,
                size: ClaudeTheme.messageSize(14),
                color: ClaudeTheme.textPrimary
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bubbleStyle(.error)
    }

    private var renderBlocks: [RenderBlock] {
        var result: [RenderBlock] = []
        var pendingTransientTools: [ToolCall] = []
        var pendingTransientGroupStartId: String?

        func appendText(_ block: MessageBlock) {
            guard let text = block.text, !text.isEmpty else { return }
            if let lastIndex = result.indices.last,
               case .text(let previousBlock) = result[lastIndex] {
                let previous = previousBlock.text ?? ""
                let needsSpace = !(previous.last?.isWhitespace ?? true) && !(text.first?.isWhitespace ?? true)
                let joined = needsSpace ? previous + " " + text : previous + text
                result[lastIndex] = .text(.text(joined, id: previousBlock.id))
            } else {
                result.append(.text(block))
            }
        }

        func flushTransientTools() {
            guard !pendingTransientTools.isEmpty else { return }
            let startId = pendingTransientGroupStartId ?? pendingTransientTools[0].id
            result.append(.transientTools(
                id: "transient-tools-\(startId)-\(pendingTransientTools.count)",
                tools: pendingTransientTools
            ))
            pendingTransientTools = []
            pendingTransientGroupStartId = nil
        }

        for block in message.blocks {
            if block.isText {
                flushTransientTools()
                appendText(block)
                continue
            }

            guard let toolCall = block.toolCall else { continue }
            if message.isStreaming {
                flushTransientTools()
                result.append(.tool(toolCall))
                continue
            }

            if ToolCategory(toolName: toolCall.name).isTransient {
                guard toolCall.result != nil || toolCall.isError else { continue }
                if pendingTransientGroupStartId == nil {
                    pendingTransientGroupStartId = toolCall.id
                }
                pendingTransientTools.append(toolCall)
            } else if toolCall.isKeepAlways || toolCall.result != nil || toolCall.isError {
                flushTransientTools()
                result.append(.tool(toolCall))
            }
        }

        flushTransientTools()
        return result
    }
}
#endif
