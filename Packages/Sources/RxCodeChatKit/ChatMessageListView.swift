import SwiftUI
import RxCodeCore

public struct ChatMessageListView: View {
    private let messages: [ChatMessage]
    private let transientGroupMinSize: Int

    public init(messages: [ChatMessage], transientGroupMinSize: Int = 2) {
        self.messages = messages
        self.transientGroupMinSize = transientGroupMinSize
    }

    public var body: some View {
        ForEach(chatMessageGroups(messages, minGroupSize: transientGroupMinSize)) { group in
            if group.isTransientGroup {
                ChatTransientGroupSummaryView(messages: group.messages)
                    .id(group.id)
                    .transition(messageFadeTransition(role: .assistant))
                    .chatMessageListRowStyle()
            } else if let message = group.messages.first {
                ChatMessageBubble(message: message)
                    .id(message.id)
                    .transition(messageFadeTransition(role: message.role))
                    .chatMessageListRowStyle()
            }
        }
    }

    private func messageFadeTransition(role: Role) -> AnyTransition {
        let anchor: UnitPoint = role == .user ? .bottomTrailing : .bottomLeading
        return .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
    }
}

extension View {
    func chatMessageListRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 24, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct ChatTransientGroupSummaryView: View {
    let messages: [ChatMessage]

    private var allToolCalls: [ToolCall] {
        messages.flatMap { $0.blocks.compactMap(\.toolCall) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ChatTransientToolSummaryView(tools: allToolCalls)
            Spacer(minLength: 40)
        }
    }
}

struct ChatTransientToolSummaryView: View {
    let tools: [ToolCall]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: ClaudeTheme.messageSize(13)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text(String(format: String(localized: "%lld tools executed", bundle: .module), tools.count))
                        .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(tools, id: \.id) { toolCall in
                    ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                }
            }
        }
    }
}
