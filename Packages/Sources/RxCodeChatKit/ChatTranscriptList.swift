import MessageList
import RxCodeCore
import SwiftUI

public nonisolated struct ChatTranscriptAccessory: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: String, Hashable, Sendable {
        case topPadding
        case loadingPrevious
        case loadingNext
        case streamingIndicator
        case webPreview
        case custom
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public nonisolated struct ChatTranscriptListItem: Identifiable, MessageListItem, Equatable, Sendable {
    public nonisolated enum Kind: Equatable, Sendable {
        case message(ChatMessage)
        case transientGroup([ChatMessage])
        case accessory(ChatTranscriptAccessory)
    }

    public let id: String
    public let kind: Kind

    public var isUserMessage: Bool {
        guard case .message(let message) = kind else { return false }
        return message.role == .user
    }

    public var isMessageListAccessory: Bool {
        guard case .accessory = kind else { return false }
        return true
    }

    public static func message(_ message: ChatMessage) -> ChatTranscriptListItem {
        ChatTranscriptListItem(id: "message-\(message.id.uuidString)", kind: .message(message))
    }

    public static func transientGroup(_ messages: [ChatMessage]) -> ChatTranscriptListItem? {
        guard let first = messages.first else { return nil }
        return ChatTranscriptListItem(id: "group-\(first.id.uuidString)", kind: .transientGroup(messages))
    }

    public static func accessory(_ accessory: ChatTranscriptAccessory) -> ChatTranscriptListItem {
        ChatTranscriptListItem(id: "accessory-\(accessory.id)", kind: .accessory(accessory))
    }

    @MainActor public static func items(
        for messages: [ChatMessage],
        transientGroupMinSize: Int = 2
    ) -> [ChatTranscriptListItem] {
        chatMessageGroups(messages, minGroupSize: transientGroupMinSize).compactMap { group in
            if group.isTransientGroup {
                return transientGroup(group.messages)
            }
            guard let message = group.messages.first else { return nil }
            return .message(message)
        }
    }
}

public struct ChatTranscriptList<AccessoryContent: View>: View {
    private let items: [ChatTranscriptListItem]
    private let isStreaming: Bool
    private let shouldScrollToBottom: Bool
    private let scrollToBottomAnimated: Bool
    @Binding private var isAtBottom: Bool
    private let hasMorePrevious: () -> Bool
    private let loadMorePrevious: (() async throws -> Void)?
    private let onLoadError: (MessageListLoadDirection, Error) -> Void
    private let rowPadding: EdgeInsets
    private let accessibilityIdentifier: String?
    private let accessoryContent: (ChatTranscriptAccessory) -> AccessoryContent

    public init(
        items: [ChatTranscriptListItem],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        scrollToBottomAnimated: Bool = true,
        isAtBottom: Binding<Bool> = .constant(true),
        hasMorePrevious: @escaping () -> Bool = { false },
        loadMorePrevious: (() async throws -> Void)? = nil,
        onLoadError: @escaping (MessageListLoadDirection, Error) -> Void = { _, _ in },
        rowPadding: EdgeInsets? = nil,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder accessoryContent: @escaping (ChatTranscriptAccessory) -> AccessoryContent
    ) {
        self.items = items
        self.isStreaming = isStreaming
        self.shouldScrollToBottom = shouldScrollToBottom
        self.scrollToBottomAnimated = scrollToBottomAnimated
        self._isAtBottom = isAtBottom
        self.hasMorePrevious = hasMorePrevious
        self.loadMorePrevious = loadMorePrevious
        self.onLoadError = onLoadError
        self.rowPadding = rowPadding ?? Self.defaultRowPadding
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessoryContent = accessoryContent
    }

    public var body: some View {
        MessageList(
            messages: items,
            isStreaming: isStreaming,
            shouldScrollToBottom: shouldScrollToBottom,
            scrollToBottomAnimated: scrollToBottomAnimated,
            isAtBottom: $isAtBottom,
            hasMorePrevious: hasMorePrevious,
            loadMorePrevious: loadMorePrevious,
            onLoadError: onLoadError
        ) { item in
            rowContent(for: item)
                .padding(rowPadding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    @ViewBuilder
    private func rowContent(for item: ChatTranscriptListItem) -> some View {
        switch item.kind {
        case .message(let message):
            ChatMessageBubble(message: message)
                .transition(messageFadeTransition(role: message.role))
        case .transientGroup(let messages):
            ChatTransientGroupSummaryView(messages: messages)
                .transition(messageFadeTransition(role: .assistant))
        case .accessory(let accessory):
            accessoryContent(accessory)
        }
    }

    private func messageFadeTransition(role: Role) -> AnyTransition {
        let anchor: UnitPoint = role == .user ? .bottomTrailing : .bottomLeading
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
                .animation(.spring(duration: 0.25, bounce: 0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        )
    }

    private static var defaultRowPadding: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20)
        #else
        EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        #endif
    }
}
