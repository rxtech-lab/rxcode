import AgentMessageListUI
import RxCodeCore
import SwiftUI

public nonisolated struct ChatTranscriptAccessory: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: String, Hashable, Sendable {
        case topPadding
        case loadingPrevious
        case loadingNext
        case streamingIndicator
        case endActions
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
    @State private var navigation = TranscriptMessageNavigation()
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
        let latestUserID = items.last(where: \.isUserMessage)?.id
        let readingHistory = navigation.isReadingHistory(latestUserID: latestUserID)
        MessageList(
            messages: readingHistory ? rowsReleasingPin(on: latestUserID) : items,
            isStreaming: isStreaming && !readingHistory,
            shouldScrollToBottom: shouldScrollToBottom,
            scrollToBottomAnimated: scrollToBottomAnimated,
            userMessagePinning: readingHistory ? .never : .whileStreaming,
            isAtBottom: Binding(
                get: { !readingHistory && isAtBottom },
                set: { value in
                    if !navigation.isReadingHistory(latestUserID: latestUserID) { isAtBottom = value }
                }
            ),
            hasMorePrevious: hasMorePrevious,
            loadMorePrevious: loadMorePrevious,
            onLoadError: onLoadError
        ) { item in
            rowContent(for: item)
                .padding(rowPadding)
                .background {
                    TranscriptScrollReader(surface: navigation.surface)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .overlay(alignment: .trailing) {
            TranscriptMessageSliderOverlay(items: items, navigation: navigation) { row in
                guard let latestUserID else { return }
                isAtBottom = navigation.select(row: row, latestUserID: latestUserID)
            }
        }
        .onChange(of: shouldScrollToBottom) { _, requested in
            if requested { navigation.followLatest() }
        }
        .onChange(of: latestUserID) {
            // Loading an older page keeps the latest ID. A send or thread switch
            // hands positioning back to the list.
            navigation.reset()
        }
        .onDisappear { navigation.reset() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    /// MessageList retains a live turn's pin by row ID. Giving that one row a
    /// reading-mode identity releases the pin before the engine handles the
    /// end of bottom-following. The row still renders the live message.
    private func rowsReleasingPin(on latestUserID: String?) -> [ChatTranscriptListItem] {
        items.map { item in
            guard item.id == latestUserID else { return item }
            return ChatTranscriptListItem(id: "unpinned-\(item.id)", kind: item.kind)
        }
    }

    @ViewBuilder
    private func rowContent(for item: ChatTranscriptListItem) -> some View {
        switch item.kind {
        case .message(let message):
            ChatTranscriptMessageRow(item: item)
                .equatable()
                .transition(messageFadeTransition(role: message.role))
        case .transientGroup:
            ChatTranscriptMessageRow(item: item)
                .equatable()
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

/// The native list refreshes visible hosting configurations even when only a
/// streaming accessory changed. Compare complete message values so settled
/// markdown and tool history can skip that repeated rendering work.
struct ChatTranscriptMessageRow: View, Equatable {
    let item: ChatTranscriptListItem

    var body: some View {
        switch item.kind {
        case .message(let message):
            ChatMessageBubble(message: message)
        case .transientGroup(let messages):
            ChatTransientGroupSummaryView(messages: messages)
        case .accessory:
            EmptyView()
        }
    }
}
