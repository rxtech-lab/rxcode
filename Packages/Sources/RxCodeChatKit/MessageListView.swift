import SwiftUI
import Combine
import RxCodeCore

#if os(macOS)

nonisolated enum MessageListViewScrollPolicy {
    static func shouldRequestLiveBottomScroll(wasAtBottom: Bool) -> Bool {
        wasAtBottom
    }
}

/// Message scroll area — extracted from ChatView to isolate @Observable
/// dependencies on `messages`.
///
/// Behavior: freshly opened threads and new sends bring the latest turn into
/// view. Live assistant updates follow the bottom only while the user is still
/// at the bottom, so reading older messages is not interrupted by streaming
/// deltas or the streaming-to-settled handoff.
struct MessageListView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    @State private var settledItems: [ChatMessage] = []
    /// Pre-grouped rows for `settledItems`. Streaming deltas re-evaluate this
    /// view frequently, so rebuilding every historical row from `settledItems`
    /// in `body` makes long threads do work proportional to their full history
    /// for every delta.
    @State private var settledTranscriptItems: [ChatTranscriptListItem] = []
    /// Owns the debounced content-growth scroll.
    @State private var scrollTask: Task<Void, Never>?
    /// Owns the multi-frame "settle at the bottom" sweep used on session open
    /// and the streaming→settled handoff. Separate from `scrollTask` so a
    /// concurrent `scrollToBottomDebounced()` can't cancel it.
    @State private var settleScrollTask: Task<Void, Never>?
    /// Owns the fade-in. A separate handle so the content-growth path
    /// (`scrollToBottomDebounced`, which owns `scrollTask`) can't cancel the
    /// session-ready flip.
    @State private var readyTask: Task<Void, Never>?
    @State private var anchor = AutoScrollAnchor()
    @State private var isSessionReady = false
    /// Latest scroll phase — gates auto-scroll so it never fires while the user
    /// is driving the scroll.
    @State private var scrollPhase: ScrollPhase = .idle
    /// Re-asserts a freshly sent user message at the top while lazy layout,
    /// streaming rows, and the dynamic tail spacer settle.
    @State private var pinToTopTask: Task<Void, Never>?
    @State private var scrollViewHeight: CGFloat = 0
    @State private var latestUserMinY: CGFloat = 0
    @State private var tailSpacerMinY: CGFloat = 0
    @State private var activeTurnUserMessageID: UUID?
    @State private var isPinningLatestTurnToTop = false
    @State private var canReleasePinnedTurnByScroll = false
    @State private var pendingIndicatorSpacerReduction: CGFloat = 0
    @State private var activeTurnMaxMeasuredHeight: CGFloat = 0
    @State private var lastBottomScrollDate = Date.distantPast
    @State private var shouldScrollToBottom = false
    /// Whether the next `shouldScrollToBottom` request should animate. The
    /// stream-end re-assertion sets this false: the streaming→settled row handoff
    /// reflows the lazy list and snaps the offset, and an animated correction on
    /// top of that reads as a visible "scroll up, then glide to the end" jump.
    @State private var scrollToBottomAnimated = true
    @State private var isAtBottom = true
    @State private var scrollRequestTask: Task<Void, Never>?

    private static let bottomAnchorID = "message-list-bottom-anchor"
    private static let endOfScreenAnchorID = "message-list-end-of-screen"
    private static let userScrollDownDelta: CGFloat = 4
    private static let streamingIndicatorEstimatedHeight: CGFloat = 36
    private static let contentGrowthBottomScrollInterval: TimeInterval = 1
    private static let pinToTopAnimationDuration: Duration = .milliseconds(320)
    private static let pinToTopAnimationSeconds: Double = 0.32

    var body: some View {
        messageList
    }

    /// The rows inside the scroll content — extracted so the type-checker handles the
    /// content separately from the long modifier chain in `messageList`.
    @ViewBuilder
    private var messageListRows: some View {
        messageRows(settledItems[...])

        // Streaming view is outside VStack — text deltas don't affect settled layout
        if !windowState.focusMode {
            StreamingMessageView {
                rebuildSettledItems()
            }
            // Suppress layout animations when switching sessions so the pulse indicator
            // doesn't visually jump as StreamingMessageView changes height.
            .animation(.none, value: windowState.currentSessionId)
            .chatMessageListRowStyle()
        }

        if chatBridge.isStreaming && !chatBridge.hasPendingPlanDecision {
            // Hide the spinner/dots while the CLI is paused waiting on the
            // user's plan decision — the model isn't actually generating
            // tokens, so showing "in progress" is misleading.
            HStack(alignment: .top, spacing: 0) {
                StreamingIndicatorView(
                    isThinking: chatBridge.isThinking,
                    startDate: chatBridge.streamingStartDate,
                    agentProvider: chatBridge.agentProvider,
                    outputTokens: chatBridge.liveOutputTokens
                )
                Spacer(minLength: 40)
            }
            .chatMessageListRowStyle()
        }

        if !chatBridge.isStreaming && !settledItems.isEmpty {
            WebPreviewButton(messages: settledItems)
                .id("web-preview")
                .chatMessageListRowStyle()
        }

        Color.clear
            .frame(height: 1)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(chatContentCoordinateSpace)).minY
            } action: { newValue in
                updateTailSpacerMinY(newValue)
            }

        Color.clear
            .frame(height: 1)
            .id(Self.endOfScreenAnchorID)

        Color.clear
            .frame(height: minTailSpacer)

        Color.clear
            .frame(height: pinTailSpacerExtraHeight)

        bottomAnchor
    }

    /// A 1pt sentinel row at the end of the transcript — the target every
    /// scroll-to-bottom aims at.
    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
    }

    private var messageList: some View {
        let base = ChatTranscriptList(
            items: transcriptItems,
            isStreaming: chatBridge.isStreaming,
            shouldScrollToBottom: shouldScrollToBottom,
            scrollToBottomAnimated: scrollToBottomAnimated,
            isAtBottom: $isAtBottom
        ) { accessory in
            transcriptAccessory(accessory)
        }
            .opacity(isSessionReady || shouldShowEndLoadingIndicator ? 1 : 0)
        let scrolling = base
            .task(id: windowState.currentSessionId) {
                await handleSessionTask()
            }
        return scrolling
            .onChange(of: chatBridge.isLoadingFromDisk) { _, isLoading in
                handleLoadingChange(isLoading)
            }
            .onChange(of: chatBridge.isStreaming) { old, new in
                handleStreamingChange(old: old, new: new)
            }
            .onChange(of: chatBridge.sendRequestID) { _, _ in
                prepareForNewUserSend()
            }
            .onChange(of: chatBridge.messages.last?.id) { _, _ in
                handleLastMessageChange()
            }
            // Synthetic hook/auto-continue cards mutate the last message in
            // place (result: nil → result) without changing its id, content, or
            // the session-level isStreaming flag, so none of the other rebuild
            // triggers fire. They flip isResponseComplete when the result lands;
            // observe it so the running card refreshes to its result live
            // instead of only after a reload.
            .onChange(of: chatBridge.messages.last?.isResponseComplete) { _, _ in
                handleLastMessageChange()
            }
            .onChange(of: chatBridge.messages.last?.content) { _, _ in
                guard isSessionReady else { return }
                requestScrollToBottomIfAtBottom()
            }
            .onChange(of: isSessionReady) { _, new in
                PerformanceDiagnostics.increment(new ? "chat.session_ready.true" : "chat.session_ready.false")
            }
            .onChange(of: settledItems.count) { _, new in
                PerformanceDiagnostics.record("chat.settled_items", value: Double(new))
            }
            .overlay {
                if settledItems.isEmpty && !chatBridge.isStreaming && windowState.currentSessionId == nil {
                    EmptySessionView()
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Session lifecycle

    private func handleSessionTask() async {
        PerformanceDiagnostics.increment("chat.session_task.fired")
        PerformanceDiagnostics.record("chat.bridge_messages", value: Double(chatBridge.messages.count))
        // When the CLI emits its first `system:init` event mid-stream, AppState
        // swaps currentSessionId from the local "pending-..." placeholder to
        // the real CLI sid. That id change re-fires this task even though the
        // user did not switch sessions — fading out here causes a visible blink.
        // Detect that case via chatBridge.isStreaming and keep the list visible.
        if chatBridge.isStreaming {
            rebuildSettledItems()
            if !isSessionReady { isSessionReady = true }
            requestScrollToBottomIfAtBottom()
            PerformanceDiagnostics.increment("chat.session_task.streaming_path")
            return
        }
        isSessionReady = false
        scrollTask?.cancel()
        scrollTask = nil
        settleScrollTask?.cancel()
        readyTask?.cancel()
        pinToTopTask?.cancel()
        cancelScrollRequest()
        activeTurnUserMessageID = nil
        isPinningLatestTurnToTop = false
        canReleasePinnedTurnByScroll = false
        pendingIndicatorSpacerReduction = 0
        activeTurnMaxMeasuredHeight = 0
        rebuildSettledItems()
        // Empty sessions appear instantly — unless we're still loading persisted
        // messages from disk, in which case `handleLoadingChange` fades the list
        // in once messages arrive, avoiding the empty → populated "blink".
        guard !settledItems.isEmpty else {
            if !chatBridge.isLoadingFromDisk {
                isSessionReady = true
            }
            return
        }
        // Re-assert the bottom across several frames: a single scroll can fire
        // before the lazy stack has realized the freshly-rebuilt rows, stranding the
        // view at the top — which the fade-in would then reveal.
        requestScrollToBottom()
        anchor.resetToBottom()
        try? await Task.sleep(for: .milliseconds(48))  // let the first re-asserts land before fade-in
        withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
    }

    private func handleLoadingChange(_ isLoading: Bool) {
        PerformanceDiagnostics.increment(isLoading ? "chat.disk_loading.started" : "chat.disk_loading.finished")
        // When a background disk load finishes for a freshly switched session,
        // rebuild the settled list and fade in — same sequence as the .task above.
        guard !isLoading else { return }
        rebuildSettledItems()
        readyTask?.cancel()
        requestScrollToBottom()
        anchor.resetToBottom()
        // Fade-in lives on `readyTask` so the content-growth path
        // (`scrollToBottomDebounced`, which owns `scrollTask`) cannot cancel it.
        readyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(48))
            guard !Task.isCancelled, !isSessionReady else { return }
            withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
        }
    }

    private func handleStreamingChange(old: Bool, new: Bool) {
        logScrollState("streamingChange")
        let wasAtBottom = isAtBottom
        // Only react when streaming ends — the settled list doesn't change at start.
        guard old && !new else {
            requestScrollToBottomIfAtBottom(wasAtBottom)
            return
        }
        pendingIndicatorSpacerReduction = 0
        rebuildSettledItems()
        // The just-finished turn moves out of `StreamingMessageView` and into
        // the settled list. That row handoff makes the scroll content reload and can
        // momentarily snap the offset. Re-assert the bottom only if the user was
        // still following the bottom before the handoff.
        if wasAtBottom {
            anchor.resetToBottom()
            // Non-animated: the row handoff above already reflowed the list and
            // snapped the offset. An animated correction on top of that reads as a
            // visible "scroll up, then glide back to the end" jump; snapping puts
            // the bottom back in the same beat as the reflow.
            requestScrollToBottom(animated: false)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func messageRows(_ messages: some RandomAccessCollection<ChatMessage>) -> some View {
        ChatMessageListView(messages: Array(messages))
    }

    private var transcriptItems: [ChatTranscriptListItem] {
        var items: [ChatTranscriptListItem] = [
            .accessory(.init(id: "desktop-top-padding", kind: .topPadding)),
        ]
        items += settledTranscriptItems

        if !windowState.focusMode {
            let activeMessages = activeResponseMessages(from: chatBridge.messages)
            let transientMinSize = activeMessages.contains(where: \.isStreaming) ? 1 : 2
            items += ChatTranscriptListItem.items(for: activeMessages, transientGroupMinSize: transientMinSize)
        }

        if shouldShowEndLoadingIndicator {
            items.append(.accessory(.init(id: "desktop-end-loading-indicator", kind: .loadingNext)))
        }

        if !chatBridge.isStreaming && !settledItems.isEmpty {
            items.append(.accessory(.init(id: "desktop-web-preview", kind: .webPreview)))
        }
        return items
    }

    private var shouldShowEndLoadingIndicator: Bool {
        (chatBridge.isLoadingFromDisk && chatBridge.messages.isEmpty)
            || (chatBridge.isStreaming && !chatBridge.hasPendingPlanDecision)
    }

    @ViewBuilder
    private func transcriptAccessory(_ accessory: ChatTranscriptAccessory) -> some View {
        switch accessory.kind {
        case .topPadding:
            Color.clear.frame(height: 16)
        case .loadingNext, .streamingIndicator:
            HStack(alignment: .top, spacing: 0) {
                StreamingIndicatorView(
                    isThinking: chatBridge.isThinking,
                    startDate: chatBridge.streamingStartDate,
                    agentProvider: chatBridge.agentProvider,
                    outputTokens: chatBridge.liveOutputTokens
                )
                Spacer(minLength: 40)
            }
        case .webPreview:
            WebPreviewButton(messages: settledItems)
        case .loadingPrevious, .custom:
            EmptyView()
        }
    }

    // MARK: - Settled Items

    private func rebuildSettledItems() {
        PerformanceDiagnostics.increment("chat.settled_rebuild.total")
        let messages = settledOnlyMessages(from: chatBridge.messages)
        guard messages != settledItems else {
            PerformanceDiagnostics.increment("chat.settled_rebuild.skipped_unchanged")
            return
        }
        let transcriptItems = ChatTranscriptListItem.items(for: messages)
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            settledItems = messages
            settledTranscriptItems = transcriptItems
        }
        PerformanceDiagnostics.increment("chat.settled_rebuild.applied")
    }

    private func handleLastMessageChange() {
        guard isSessionReady, !chatBridge.isLoadingFromDisk else { return }
        let wasAtBottom = isAtBottom
        rebuildSettledItems()
        guard let last = chatBridge.messages.last else { return }
        logScrollState("lastMessageChange")
        if last.role != .user {
            requestScrollToBottomIfAtBottom(wasAtBottom)
        }
    }

    private func prepareForNewUserSend() {
        logScrollState("prepareForNewUserSend")
        scrollTask?.cancel()
        scrollTask = nil
        settleScrollTask?.cancel()
        pinToTopTask?.cancel()
        cancelScrollRequest()
        activeTurnUserMessageID = nil
        isPinningLatestTurnToTop = false
        canReleasePinnedTurnByScroll = false
        pendingIndicatorSpacerReduction = 0
        activeTurnMaxMeasuredHeight = 0
    }

    private func requestScrollToBottom(animated: Bool = true) {
        // Coalesce: streaming fires this once per token via the `content`
        // onChange. Cancelling and reallocating the task — plus toggling
        // `shouldScrollToBottom` false→true — on every token is pure per-token
        // churn. If a request with the same animation intent is already in
        // flight, let it land instead of rebuilding it; only a differing intent
        // (e.g. the non-animated stream-end re-assert) supersedes it.
        let coalesced = scrollRequestTask != nil && scrollToBottomAnimated == animated
        PerformanceDiagnostics.increment("chat.scroll_request.total")
        if coalesced { PerformanceDiagnostics.increment("chat.scroll_request.coalesced") }
        if chatBridge.isStreaming { PerformanceDiagnostics.increment("chat.scroll_request.streaming") }
        if animated { PerformanceDiagnostics.increment("chat.scroll_request.animated") }
        if scrollRequestTask != nil, scrollToBottomAnimated == animated {
            return
        }
        cancelScrollRequest()
        shouldScrollToBottom = false
        scrollToBottomAnimated = animated
        scrollRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            scrollRequestTask = nil
            shouldScrollToBottom = true
        }
    }

    /// Cancels any in-flight scroll request and clears the handle so the
    /// coalescing guard in `requestScrollToBottom` doesn't see a dead task as
    /// "still pending" and block future requests.
    private func cancelScrollRequest() {
        scrollRequestTask?.cancel()
        scrollRequestTask = nil
    }

    private func requestScrollToBottomIfAtBottom(_ atBottom: Bool? = nil, animated: Bool = true) {
        let shouldFollowBottom = atBottom ?? isAtBottom
        guard MessageListViewScrollPolicy.shouldRequestLiveBottomScroll(wasAtBottom: shouldFollowBottom) else {
            logScrollState("scrollToBottom.skippedNotAtBottom")
            return
        }
        requestScrollToBottom(animated: animated)
    }

    /// Returns the last consecutive assistant sequence (including streaming turn) while streaming.
    /// Returns an empty array when not streaming so no separate streaming rows render.
    private func activeResponseMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.last?.isStreaming == true else { return [] }
        return chatSuppressPlanReadyFollowups(in: Array(messages[chatStreamingBoundaryIndex(in: messages)...]))
    }

    /// If streaming, returns only completed messages excluding the last consecutive (non-error) assistant sequence.
    /// If not streaming, returns all messages without the streaming flag.
    /// In focus mode, further filters to only user messages and completed assistant responses.
    private func settledOnlyMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        var settled: [ChatMessage]
        if messages.last?.isStreaming == true {
            let boundary = chatStreamingBoundaryIndex(in: messages)
            settled = Array(messages[..<boundary]).filter { !$0.isStreaming }
        } else {
            settled = messages.filter { !$0.isStreaming }
        }
        if windowState.focusMode {
            settled = settled.filter { $0.role == .user || $0.isResponseComplete || $0.isCompactBoundary }
        }
        return chatSuppressPlanReadyFollowups(in: settled)
    }

    // MARK: - Scrolling

    /// `true` while the user is driving the scroll — finger/trackpad down or a
    /// post-flick glide. Our own programmatic `.animating` scroll and the
    /// settled `.idle` state are not user-driven.
    private var isUserDrivenScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking, .decelerating: return true
        case .idle, .animating: return false
        @unknown default: return false
        }
    }

    /// A stricter check for releasing the mobile-style top pin. Desktop scroll
    /// animations can pass through `.decelerating`; treating that as a release
    /// makes the programmatic pin immediately bounce back to the bottom.
    private var isDirectUserScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking: return true
        case .idle, .animating, .decelerating: return false
        @unknown default: return false
        }
    }

    /// The user message whose geometry drives the active turn spacer.
    private var trackedUserMessageID: UUID? {
        activeTurnUserMessageID ?? settledItems.last(where: { $0.role == .user })?.id
    }

    private var minTailSpacer: CGFloat {
        16
    }

    /// Extra spacer for the active turn. It starts large enough for the sent
    /// user message to sit at the top, then shrinks as the assistant response
    /// grows into that space.
    private var pinTailSpacerExtraHeight: CGFloat {
        guard activeTurnUserMessageID != nil else { return 0 }
        guard scrollViewHeight > 0 else { return 0 }
        let latestTurnHeight = max(activeTurnMaxMeasuredHeight, rawActiveTurnMeasuredHeight)
        return max(0, scrollViewHeight - latestTurnHeight - minTailSpacer)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        logScrollState("scrollToBottom.now")
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// Coalesced scroll-to-bottom for content growth. Streaming can update the
    /// geometry once per token; keep bottom-follow to at most one scroll per
    /// second so it doesn't fight SwiftUI's lazy layout.
    private func scrollToBottomDebounced(_ proxy: ScrollViewProxy) {
        guard scrollTask == nil else { return }
        logScrollState("scrollToBottom.debounceScheduled")
        let elapsed = Date().timeIntervalSince(lastBottomScrollDate)
        let delay = max(0, Self.contentGrowthBottomScrollInterval - elapsed)
        scrollTask = Task { @MainActor in
            let delayNanoseconds = UInt64(delay * 1_000_000_000)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            scrollTask = nil
            guard !isUserDrivenScroll, !isPinningLatestTurnToTop else { return }
            lastBottomScrollDate = Date()
            logScrollState("scrollToBottom.debounceFired")
            scrollToBottom(proxy)
        }
    }

    /// Re-assert the bottom on every frame for a short window.
    ///
    /// A single scroll can land before the lazy stack has realized the freshly-rebuilt
    /// rows (session open / disk load), or while the streaming→settled row
    /// handoff is still reloading the list — in both cases the offset snaps to
    /// the top. Re-asserting corrects the snap within a frame, before it becomes
    /// visible. Bails the moment the user grabs the scroll so it never fights a
    /// drag — our own `.animating` scroll is not user-driven.
    private func settleAtBottom(proxy: ScrollViewProxy, reason: String) {
        settleScrollTask?.cancel()
        PerformanceDiagnostics.increment("chat.scroll_settle.\(reason)")
        settleScrollTask = Task { @MainActor in
            for _ in 0..<12 {
                guard !Task.isCancelled, !isUserDrivenScroll else { return }
                scrollToBottom(proxy)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Pin a freshly sent user message to the top of the viewport.
    private func pinSentMessageToTop(_ id: UUID, proxy: ScrollViewProxy, animated: Bool) {
        scrollTask?.cancel()
        scrollTask = nil
        settleScrollTask?.cancel()
        pinToTopTask?.cancel()
        canReleasePinnedTurnByScroll = false
        logScrollState("pinTop.scheduled")
        pinToTopTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            if animated {
                guard !Task.isCancelled else { return }
                logScrollState("pinTop.animated")
                withAnimation(.easeInOut(duration: Self.pinToTopAnimationSeconds)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                try? await Task.sleep(for: Self.pinToTopAnimationDuration)
            }
            for attempt in 0..<8 {
                guard !Task.isCancelled else { return }
                if attempt == 0 || attempt == 7 {
                    logScrollState("pinTop.settle")
                }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(id, anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, isPinningLatestTurnToTop else { return }
            canReleasePinnedTurnByScroll = true
            logScrollState("pinTop.armedRelease")
        }
    }

    private func repinActiveTurnIfNeeded(proxy: ScrollViewProxy) -> Bool {
        guard isPinningLatestTurnToTop, let id = activeTurnUserMessageID else {
            return false
        }
        pinSentMessageToTop(id, proxy: proxy, animated: false)
        return true
    }

    private func releasePinnedTurnToBottom(proxy: ScrollViewProxy) {
        logScrollState("pinTop.releaseToBottom")
        pinToTopTask?.cancel()
        canReleasePinnedTurnByScroll = false
        isPinningLatestTurnToTop = false
        pendingIndicatorSpacerReduction = 0
        anchor.resetToBottom()
        scrollTask?.cancel()
        scrollTask = nil
        lastBottomScrollDate = Date()
        scrollToBottom(proxy)
    }

    /// `minY` of the latest user message — fed back from `ChatMessageListView`.
    private func updateLatestUserMinY(_ value: CGFloat) {
        guard abs(value - latestUserMinY) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { latestUserMinY = value }
        updateActiveTurnMaxMeasuredHeight()
        logScrollState("latestUserMinY.updated")
    }

    /// `minY` of the tail spacer — its distance from the user message is the
    /// height of the latest turn.
    private func updateTailSpacerMinY(_ value: CGFloat) {
        guard abs(value - tailSpacerMinY) > 0.5 else { return }
        let oldValue = tailSpacerMinY
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            tailSpacerMinY = value
            if pendingIndicatorSpacerReduction > 0, value > oldValue {
                pendingIndicatorSpacerReduction = 0
            }
        }
        updateActiveTurnMaxMeasuredHeight()
        logScrollState("tailSpacerMinY.updated")
    }

    private var rawActiveTurnMeasuredHeight: CGFloat {
        max(0, tailSpacerMinY - latestUserMinY) + pendingIndicatorSpacerReduction
    }

    private func startActiveTurn(_ id: UUID) {
        activeTurnUserMessageID = id
        activeTurnMaxMeasuredHeight = 0
        updateActiveTurnMaxMeasuredHeight()
    }

    private func updateActiveTurnMaxMeasuredHeight() {
        guard activeTurnUserMessageID != nil else { return }
        let measured = rawActiveTurnMeasuredHeight
        guard measured > activeTurnMaxMeasuredHeight + 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            activeTurnMaxMeasuredHeight = measured
        }
    }

    private func logScrollState(_ label: String) {
        PerformanceDiagnostics.increment("chat.scroll_state.\(label)")
    }
}

// MARK: - Streaming Message (isolated view — chatBridge.messages dependency confined to this view)

struct StreamingMessageView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    var onStructureChanged: () -> Void

    var body: some View {
        let messages = chatBridge.messages
        let activeMessages = activeResponseMessages(from: messages)
        let (settledActive, streamingActive) = chatPartitionByStreaming(activeMessages)
        Group {
            if !activeMessages.isEmpty {

                if !streamingActive.isEmpty {
                    // Collapse completed transient tool calls (even a single one) the moment
                    // the next streaming message begins, so only the current message stays visible.
                    let groups = chatMessageGroups(settledActive, minGroupSize: 1)
                    ForEach(groups) { group in
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
                } else {
                    // Nothing streaming yet — show each settled message individually.
                    ForEach(settledActive, id: \.id) { message in
                        ChatMessageBubble(message: message)
                            .id(message.id)
                            .transition(streamFadeTransition(role: message.role))
                    }
                }

                ForEach(streamingActive, id: \.id) { message in
                    ChatMessageBubble(message: message)
                        .id(message.id)
                        .transition(streamFadeTransition(role: .assistant))
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
