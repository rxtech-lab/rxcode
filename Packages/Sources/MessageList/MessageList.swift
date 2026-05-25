import Foundation
import SwiftUI

public protocol MessageListItem: Identifiable, Sendable where ID: Hashable & Sendable {
    var isUserMessage: Bool { get }
    var isMessageListAccessory: Bool { get }
}

public extension MessageListItem {
    var isMessageListAccessory: Bool { false }
}

public enum MessageListLoadDirection: Sendable, Equatable {
    case previous
    case next
}

public struct MessageList<Message: MessageListItem, RowContent: View>: View {
    private let messages: [Message]
    private let isStreaming: Bool
    private let shouldScrollToBottom: Bool
    @Binding private var isAtBottom: Bool
    private let hasMorePrevious: () -> Bool
    private let hasMore: () -> Bool
    private let loadMorePrevious: (() async throws -> Void)?
    private let loadMore: (() async throws -> Void)?
    private let onLoadError: (MessageListLoadDirection, Error) -> Void
    private let rowContent: (Message) -> RowContent

    @State private var anchor = MessageListScrollAnchor()
    @State private var pinning = MessageListPinningController<Message.ID>()
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var scrollViewHeight: CGFloat = 0
    @State private var latestUserMinY: CGFloat = 0
    @State private var tailMarkerMinY: CGFloat = 0
    @State private var activeTurnMaxMeasuredHeight: CGFloat = 0
    @State private var canReleasePinnedUserMessageByScroll = false
    @State private var pinTask: Task<Void, Never>?
    @State private var bottomScrollTask: Task<Void, Never>?
    @State private var lastStreamingBottomScrollDate = Date.distantPast
    @State private var isLoadingPrevious = false
    @State private var isLoadingNext = false
    @State private var previousLoadContentHeight: CGFloat?
    @State private var nextLoadContentHeight: CGFloat?
    @State private var previousLoadCooldownUntil: Date = .distantPast
    @State private var nextLoadCooldownUntil: Date = .distantPast

    public init(
        messages: [Message],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        isAtBottom: Binding<Bool> = .constant(true),
        hasMorePrevious: @escaping () -> Bool = { false },
        hasMore: @escaping () -> Bool = { false },
        loadMorePrevious: (() async throws -> Void)? = nil,
        loadMore: (() async throws -> Void)? = nil,
        onLoadError: @escaping (MessageListLoadDirection, Error) -> Void = { _, _ in },
        @ViewBuilder rowContent: @escaping (Message) -> RowContent
    ) {
        self.messages = messages
        self.isStreaming = isStreaming
        self.shouldScrollToBottom = shouldScrollToBottom
        self._isAtBottom = isAtBottom
        self.hasMorePrevious = hasMorePrevious
        self.hasMore = hasMore
        self.loadMorePrevious = loadMorePrevious
        self.loadMore = loadMore
        self.onLoadError = onLoadError
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topLoadTrigger

                    ForEach(messages) { message in
                        let messageID = message.id
                        rowContent(message)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .named(MessageListConstants.coordinateSpaceName)).minY
                            } action: { value in
                                guard messageID == pinning.pinnedUserMessageID else { return }
                                updateLatestUserMinY(value)
                            }
                            .id(messageID)
                    }

                    tailMarker
                    bottomLoadTrigger
                    pinTailSpacer
                    bottomAnchor
                }
                .coordinateSpace(.named(MessageListConstants.coordinateSpaceName))
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                scrollViewHeight = height
                updateActiveTurnMaxMeasuredHeight()
            }
            .onScrollGeometryChange(for: MessageListScrollMetrics.self) { geometry in
                MessageListScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    visibleMinY: geometry.visibleRect.minY,
                    visibleMaxY: geometry.visibleRect.maxY
                )
            } action: { _, metrics in
                handleScrollMetrics(metrics, proxy: proxy)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { oldOffsetY, offsetY in
                guard isDirectUserScroll,
                      pinning.isPinningUserMessage,
                      canReleasePinnedUserMessageByScroll,
                      offsetY > oldOffsetY + MessageListConstants.userScrollDownDelta
                else { return }
                releasePinnedUserMessage(proxy: proxy)
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
            }
            .task {
                if shouldScrollToBottom {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                guard shouldScroll else { return }
                guard !pinning.isPinningUserMessage else { return }
                anchor.resetToBottom()
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: isStreaming) { oldValue, newValue in
                if !newValue {
                    lastStreamingBottomScrollDate = .distantPast
                }
                applyPinningAction(
                    pinning.handleStreamingChange(
                        oldValue: oldValue,
                        newValue: newValue,
                        isAtBottom: isAnchoredAtBottom
                    ),
                    proxy: proxy
                )
            }
            .onChange(of: messageListChangeToken) { oldToken, newToken in
                handleMessageListChange(oldToken: oldToken, newToken: newToken, proxy: proxy)
            }
        }
    }

    private var topLoadTrigger: some View {
        Color.clear.frame(height: 1)
    }

    private var tailMarker: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.tailMarkerID)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .named(MessageListConstants.coordinateSpaceName)).minY
            } action: { value in
                updateTailMarkerMinY(value)
            }
    }

    private var bottomLoadTrigger: some View {
        Color.clear.frame(height: 1)
    }

    private var pinTailSpacer: some View {
        Color.clear.frame(height: pinTailSpacerHeight)
    }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.bottomAnchorID)
    }

    private var isUserDrivenScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking, .decelerating:
            true
        case .idle, .animating:
            false
        @unknown default:
            false
        }
    }

    private var isDirectUserScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking:
            true
        case .idle, .animating, .decelerating:
            false
        @unknown default:
            false
        }
    }

    private var pinTailSpacerHeight: CGFloat {
        guard pinning.isPinningUserMessage, scrollViewHeight > 0 else { return 0 }
        return max(0, scrollViewHeight - activeTurnHeight - MessageListConstants.minimumPinnedTailSpacing)
    }

    private var rawActiveTurnMeasuredHeight: CGFloat {
        max(0, tailMarkerMinY - latestUserMinY)
    }

    private var activeTurnHeight: CGFloat {
        max(activeTurnMaxMeasuredHeight, rawActiveTurnMeasuredHeight)
    }

    private var pinnedTurnFillsViewport: Bool {
        guard scrollViewHeight > 0 else { return false }
        return activeTurnHeight >= scrollViewHeight - MessageListConstants.minimumPinnedTailSpacing
    }

    private var isAnchoredAtBottom: Bool {
        anchor.isNearBottom && isAtBottom
    }

    private var latestContentItem: Message? {
        messages.last { !$0.isMessageListAccessory }
    }

    private var latestUserMessageID: Message.ID? {
        messages.last { $0.isUserMessage }?.id
    }

    private var hasContentAfterPinnedUserMessage: Bool {
        guard let pinnedID = pinning.pinnedUserMessageID,
              let pinnedIndex = messages.firstIndex(where: { $0.id == pinnedID })
        else { return false }

        let nextIndex = messages.index(after: pinnedIndex)
        guard nextIndex < messages.endIndex else { return false }
        return messages[nextIndex...].contains { !$0.isMessageListAccessory }
    }

    private var shouldReleasePinnedUserMessageForFilledTurn: Bool {
        pinning.isPinningUserMessage
            && hasContentAfterPinnedUserMessage
            && pinnedTurnFillsViewport
    }

    private var messageListChangeToken: MessageListChangeToken<Message.ID> {
        MessageListChangeToken(
            ids: messages.map(\.id),
            latestContentID: latestContentItem?.id,
            latestUserMessageID: latestUserMessageID
        )
    }

    private func handleScrollMetrics(_ metrics: MessageListScrollMetrics, proxy: ScrollViewProxy) {
        let decision = anchor.apply(
            contentHeight: metrics.contentHeight,
            visibleMaxY: metrics.visibleMaxY
        )
        updateIsAtBottomBinding(anchor.isNearBottom)

        if shouldReleasePinnedUserMessageForFilledTurn, !isUserDrivenScroll {
            releasePinnedUserMessage(proxy: proxy)
        }

        if decision == .scrollToBottom,
           isAtBottom,
           isStreaming,
           !isUserDrivenScroll,
           !pinning.isPinningUserMessage {
            scheduleScrollToBottom(proxy: proxy)
        }

        if isUserDrivenScroll, metrics.visibleMinY <= MessageListConstants.loadThreshold {
            triggerLoadPreviousIfNeeded(contentHeight: metrics.contentHeight)
        } else if metrics.visibleMinY > MessageListConstants.loadThreshold {
            previousLoadContentHeight = nil
        }

        if isUserDrivenScroll, metrics.contentHeight - metrics.visibleMaxY <= MessageListConstants.loadThreshold {
            triggerLoadNextIfNeeded(contentHeight: metrics.contentHeight)
        } else if metrics.contentHeight - metrics.visibleMaxY > MessageListConstants.loadThreshold {
            nextLoadContentHeight = nil
        }
    }

    private func handleMessageListChange(
        oldToken: MessageListChangeToken<Message.ID>,
        newToken: MessageListChangeToken<Message.ID>,
        proxy: ScrollViewProxy
    ) {
        let latestContentItem = latestContentItem
        if oldToken.latestUserMessageID != newToken.latestUserMessageID,
           let latestUserMessageID = newToken.latestUserMessageID,
           isStreaming || latestContentItem?.isUserMessage == true {
            let action = pinning.handleLastMessageChange(
                id: latestUserMessageID,
                isUserMessage: true,
                isStreaming: isStreaming,
                isAtBottom: isAnchoredAtBottom
            )
            applyPinningAction(action, proxy: proxy)
            return
        }

        let action = pinning.handleLastMessageChange(
            id: latestContentItem?.id,
            isUserMessage: latestContentItem?.isUserMessage == true,
            isStreaming: isStreaming,
            isAtBottom: isAnchoredAtBottom
        )
        applyPinningAction(action, proxy: proxy)
    }

    private func updateIsAtBottomBinding(_ value: Bool) {
        guard isAtBottom != value else { return }
        isAtBottom = value
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: MessageListConstants.scrollAnimationSeconds)) {
                proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
        }
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy) {
        guard bottomScrollTask == nil else { return }
        let delayNanoseconds = scrollToBottomDelayNanoseconds()
        bottomScrollTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            bottomScrollTask = nil
            guard isAnchoredAtBottom, !isUserDrivenScroll, !pinning.isPinningUserMessage else { return }
            if isStreaming {
                lastStreamingBottomScrollDate = Date()
            }
            scrollToBottom(proxy: proxy, animated: true)
        }
    }

    private func scrollToBottomDelayNanoseconds() -> UInt64 {
        guard isStreaming else {
            return MessageListConstants.layoutSettleDelayNanoseconds
        }
        let elapsed = Date().timeIntervalSince(lastStreamingBottomScrollDate)
        let delay = max(0, MessageListConstants.streamingBottomScrollInterval - elapsed)
        return UInt64(delay * 1_000_000_000)
    }

    private func pinUserMessageToTop(_ id: Message.ID, proxy: ScrollViewProxy, animated: Bool) {
        bottomScrollTask?.cancel()
        bottomScrollTask = nil
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false

        pinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            if animated {
                withAnimation(.easeInOut(duration: MessageListConstants.pinAnimationSeconds)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                try? await Task.sleep(for: MessageListConstants.pinAnimationDuration)
            }

            for _ in 0..<8 {
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(id, anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard !Task.isCancelled, pinning.isPinningUserMessage else { return }
            canReleasePinnedUserMessageByScroll = true
        }
    }

    private func releasePinnedUserMessage(proxy: ScrollViewProxy) {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false
        pinning.releasePin()
        anchor.resetToBottom()
        updateIsAtBottomBinding(true)
        scrollToBottom(proxy: proxy, animated: true)
    }

    private func clearPinnedUserMessage() {
        pinTask?.cancel()
        pinning.clear()
        latestUserMinY = 0
        tailMarkerMinY = 0
        activeTurnMaxMeasuredHeight = 0
        canReleasePinnedUserMessageByScroll = false
    }

    private func applyPinningAction(
        _ action: MessageListPinningAction<Message.ID>,
        proxy: ScrollViewProxy
    ) {
        switch action {
        case .none:
            break
        case .clearPin:
            clearPinnedUserMessage()
        case .pinUserMessageToTop(let id):
            resetPinnedTurnMeasurements()
            canReleasePinnedUserMessageByScroll = false
            pinUserMessageToTop(id, proxy: proxy, animated: true)
        case .repinUserMessageToTop(let id):
            pinUserMessageToTop(id, proxy: proxy, animated: false)
        case .releasePinAndScrollToBottom:
            releasePinnedUserMessage(proxy: proxy)
        case .scrollToBottom:
            scheduleScrollToBottom(proxy: proxy)
        }
    }

    private func resetPinnedTurnMeasurements() {
        latestUserMinY = 0
        tailMarkerMinY = 0
        activeTurnMaxMeasuredHeight = 0
    }

    private func updateLatestUserMinY(_ value: CGFloat) {
        guard abs(value - latestUserMinY) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            latestUserMinY = value
        }
        updateActiveTurnMaxMeasuredHeight()
    }

    private func updateTailMarkerMinY(_ value: CGFloat) {
        guard abs(value - tailMarkerMinY) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            tailMarkerMinY = value
        }
        updateActiveTurnMaxMeasuredHeight()
    }

    private func updateActiveTurnMaxMeasuredHeight() {
        guard pinning.isPinningUserMessage else { return }
        let measured = rawActiveTurnMeasuredHeight
        guard measured > activeTurnMaxMeasuredHeight + 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            activeTurnMaxMeasuredHeight = measured
        }
    }

    private func triggerLoadPreviousIfNeeded(contentHeight: CGFloat) {
        guard !isLoadingPrevious,
              Date() >= previousLoadCooldownUntil,
              hasMorePrevious(),
              let loadMorePrevious,
              previousLoadContentHeight != contentHeight
        else { return }

        previousLoadContentHeight = contentHeight
        isLoadingPrevious = true
        Task { @MainActor in
            defer {
                previousLoadCooldownUntil = Date().addingTimeInterval(MessageListConstants.loadMoreCooldownSeconds)
                isLoadingPrevious = false
            }
            do {
                try await loadMorePrevious()
            } catch {
                onLoadError(.previous, error)
            }
        }
    }

    private func triggerLoadNextIfNeeded(contentHeight: CGFloat) {
        guard !isLoadingNext,
              Date() >= nextLoadCooldownUntil,
              hasMore(),
              let loadMore,
              nextLoadContentHeight != contentHeight
        else { return }

        nextLoadContentHeight = contentHeight
        isLoadingNext = true
        Task { @MainActor in
            defer {
                nextLoadCooldownUntil = Date().addingTimeInterval(MessageListConstants.loadMoreCooldownSeconds)
                isLoadingNext = false
            }
            do {
                try await loadMore()
            } catch {
                onLoadError(.next, error)
            }
        }
    }
}

nonisolated struct MessageListScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
}

private nonisolated struct MessageListChangeToken<ID: Hashable & Sendable>: Equatable {
    var ids: [ID]
    var latestContentID: ID?
    var latestUserMessageID: ID?
}

private nonisolated enum MessageListConstants {
    static let bottomAnchorID = "message-list-bottom-anchor"
    static let tailMarkerID = "message-list-tail-marker"
    static let coordinateSpaceName = "message-list-content"
    static let loadThreshold: CGFloat = 96
    static let minimumPinnedTailSpacing: CGFloat = 16
    static let userScrollDownDelta: CGFloat = 4
    static let layoutSettleDelayNanoseconds: UInt64 = 16_000_000
    static let streamingBottomScrollInterval: TimeInterval = 2
    static let loadMoreCooldownSeconds: TimeInterval = 1
    static let scrollAnimationSeconds: Double = 0.24
    static let pinAnimationDuration: Duration = .milliseconds(320)
    static let pinAnimationSeconds: Double = 0.32
}
