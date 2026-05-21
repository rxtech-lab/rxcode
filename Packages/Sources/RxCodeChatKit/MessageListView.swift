import SwiftUI
import Combine
import RxCodeCore
import os

#if os(macOS)

/// Message scroll area — extracted from ChatView to isolate @Observable
/// dependencies on `messages`.
///
/// Behavior: the transcript stays anchored to the bottom. A freshly opened
/// thread, a new send, and a streaming response all keep the latest message in
/// view. `AutoScrollAnchor` releases that anchor only when the user deliberately
/// scrolls up; `scrollPhase` keeps auto-scroll from fighting an active drag.
struct MessageListView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    @State private var settledItems: [ChatMessage] = []
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

    private static let log = Logger(subsystem: "com.claudework", category: "MessageListView")
    private static let bottomAnchorID = "message-list-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            messageList(proxy: proxy)
        }
    }

    /// The rows inside the `List` — extracted so the type-checker handles the
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

        bottomAnchor
    }

    /// A 1pt sentinel row at the end of the transcript — the target every
    /// scroll-to-bottom aims at.
    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func messageList(proxy: ScrollViewProxy) -> some View {
        let base = List { messageListRows }
            .listStyle(.plain)
            .contentMargins(.top, 16, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .opacity(isSessionReady ? 1 : 0)
            .onScrollGeometryChange(for: ScrollSample.self) { geo in
                ScrollSample(contentHeight: geo.contentSize.height, visibleMaxY: geo.visibleRect.maxY)
            } action: { _, sample in
                // Route the geometry change through AutoScrollAnchor so content
                // growth (streaming text, an Edit/Bash card expanding) keeps the
                // list glued to the bottom — only a deliberate user scroll
                // un-sticks it. Suppressed while the user drives the scroll so
                // auto-scroll never fights a drag.
                let decision = anchor.apply(contentHeight: sample.contentHeight, visibleMaxY: sample.visibleMaxY)
                if decision == .scrollToBottom, !isUserDrivenScroll {
                    scrollToBottomDebounced(proxy)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
            }
        let scrolling = base
            .task(id: windowState.currentSessionId) {
                await handleSessionTask(proxy: proxy)
            }
        return scrolling
            .onChange(of: chatBridge.isLoadingFromDisk) { _, isLoading in
                handleLoadingChange(isLoading, proxy: proxy)
            }
            .onChange(of: chatBridge.isStreaming) { old, new in
                handleStreamingChange(old: old, new: new, proxy: proxy)
            }
            .onChange(of: isSessionReady) { _, new in
                Self.log.info("[MessageList.ready] isSessionReady=\(new) sid=\(windowState.currentSessionId ?? "<nil>", privacy: .public) settled=\(settledItems.count)")
            }
            .onChange(of: settledItems.count) { _, new in
                Self.log.info("[MessageList.settled] settled=\(new) sid=\(windowState.currentSessionId ?? "<nil>", privacy: .public) isSessionReady=\(isSessionReady) isLoadingFromDisk=\(chatBridge.isLoadingFromDisk)")
            }
            .overlay {
                if settledItems.isEmpty && !chatBridge.isStreaming && windowState.currentSessionId == nil {
                    EmptySessionView()
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Session lifecycle

    private func handleSessionTask(proxy: ScrollViewProxy) async {
        let sid = windowState.currentSessionId ?? "<nil>"
        Self.log.info("[MessageList.task] fired sid=\(sid, privacy: .public) bridgeMessages=\(chatBridge.messages.count) isStreaming=\(chatBridge.isStreaming) isLoadingFromDisk=\(chatBridge.isLoadingFromDisk)")
        // When the CLI emits its first `system:init` event mid-stream, AppState
        // swaps currentSessionId from the local "pending-..." placeholder to
        // the real CLI sid. That id change re-fires this task even though the
        // user did not switch sessions — fading out here causes a visible blink.
        // Detect that case via chatBridge.isStreaming and keep the list visible.
        if chatBridge.isStreaming {
            rebuildSettledItems()
            anchor.resetToBottom()
            settleAtBottom(proxy: proxy, reason: "sessionTask.streaming")
            if !isSessionReady { isSessionReady = true }
            Self.log.info("[MessageList.task] streaming-path settled=\(settledItems.count) sid=\(sid, privacy: .public)")
            return
        }
        isSessionReady = false
        scrollTask?.cancel()
        settleScrollTask?.cancel()
        readyTask?.cancel()
        rebuildSettledItems()
        Self.log.info("[MessageList.task] post-rebuild settled=\(settledItems.count) sid=\(sid, privacy: .public) isLoadingFromDisk=\(chatBridge.isLoadingFromDisk)")
        // Empty sessions appear instantly — unless we're still loading persisted
        // messages from disk, in which case `handleLoadingChange` fades the list
        // in once messages arrive, avoiding the empty → populated "blink".
        guard !settledItems.isEmpty else {
            if !chatBridge.isLoadingFromDisk {
                isSessionReady = true
                Self.log.info("[MessageList.task] empty + not-loading → ready sid=\(sid, privacy: .public)")
            } else {
                Self.log.info("[MessageList.task] empty + still-loading → waiting for disk sid=\(sid, privacy: .public)")
            }
            return
        }
        // Re-assert the bottom across several frames: a single scroll can fire
        // before `List` has realized the freshly-rebuilt rows, stranding the
        // view at the top — which the fade-in would then reveal.
        settleAtBottom(proxy: proxy, reason: "sessionOpen")
        anchor.resetToBottom()
        try? await Task.sleep(for: .milliseconds(48))  // let the first re-asserts land before fade-in
        withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
    }

    private func handleLoadingChange(_ isLoading: Bool, proxy: ScrollViewProxy) {
        let sid = windowState.currentSessionId ?? "<nil>"
        Self.log.info("[MessageList.onLoadChange] isLoading=\(isLoading) sid=\(sid, privacy: .public) bridgeMessages=\(chatBridge.messages.count) settled=\(settledItems.count)")
        // When a background disk load finishes for a freshly switched session,
        // rebuild the settled list and fade in — same sequence as the .task above.
        guard !isLoading else { return }
        rebuildSettledItems()
        Self.log.info("[MessageList.onLoadChange] post-rebuild settled=\(settledItems.count) sid=\(sid, privacy: .public)")
        readyTask?.cancel()
        settleAtBottom(proxy: proxy, reason: "loadFinished")
        anchor.resetToBottom()
        // Fade-in lives on `readyTask` so the content-growth path
        // (`scrollToBottomDebounced`, which owns `scrollTask`) cannot cancel it.
        readyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(48))
            guard !Task.isCancelled, !isSessionReady else { return }
            withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
        }
    }

    private func handleStreamingChange(old: Bool, new: Bool, proxy: ScrollViewProxy) {
        // Only react when streaming ends — the settled list doesn't change at start.
        guard old && !new else { return }
        rebuildSettledItems()
        anchor.resetToBottom()
        // The just-finished turn moves out of `StreamingMessageView` and into
        // the settled list. That row handoff makes `List` reload and can
        // momentarily snap the offset; re-assert the bottom across the handoff.
        settleAtBottom(proxy: proxy, reason: "streamingEnded")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func messageRows(_ messages: some RandomAccessCollection<ChatMessage>) -> some View {
        ChatMessageListView(messages: Array(messages))
    }

    // MARK: - Settled Items

    private func rebuildSettledItems() {
        let messages = settledOnlyMessages(from: chatBridge.messages)
        var t = Transaction()
        t.animation = nil
        withTransaction(t) { settledItems = messages }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// Debounced scroll-to-bottom for content growth. Re-armed on every geometry
    /// change, so a burst of streaming deltas collapses into a single scroll.
    private func scrollToBottomDebounced(_ proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, !isUserDrivenScroll else { return }
            scrollToBottom(proxy)
        }
    }

    /// Re-assert the bottom on every frame for a short window.
    ///
    /// A single scroll can land before `List` has realized the freshly-rebuilt
    /// rows (session open / disk load), or while the streaming→settled row
    /// handoff is still reloading the list — in both cases the offset snaps to
    /// the top. Re-asserting corrects the snap within a frame, before it becomes
    /// visible. Bails the moment the user grabs the scroll so it never fights a
    /// drag — our own `.animating` scroll is not user-driven.
    private func settleAtBottom(proxy: ScrollViewProxy, reason: String) {
        settleScrollTask?.cancel()
        Self.log.info("[ScrollSettle] reason=\(reason, privacy: .public) sid=\(windowState.currentSessionId ?? "<nil>", privacy: .public) settled=\(settledItems.count)")
        settleScrollTask = Task { @MainActor in
            for _ in 0..<12 {
                guard !Task.isCancelled, !isUserDrivenScroll else { return }
                scrollToBottom(proxy)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
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
        .animation(.easeOut(duration: 0.28), value: activeMessages.map(\.id))
        .onChange(of: messages.count) { _, _ in
            onStructureChanged()
        }
    }

    private func streamFadeTransition(role: Role) -> AnyTransition {
        let anchor: UnitPoint = role == .user ? .bottomTrailing : .bottomLeading
        let insertion: AnyTransition = .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
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
    private let timer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(ClaudeTheme.textTertiary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .scaleEffect(phase == i ? 1.0 : 0.85)
                    .animation(.easeInOut(duration: 0.25), value: phase)
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
