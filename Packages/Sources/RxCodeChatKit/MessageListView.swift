import SwiftUI
import Combine
import RxCodeCore
import os

#if os(macOS)

/// Message scroll area — extracted from ChatView to isolate @Observable dependencies on `messages`.
struct MessageListView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    @State private var scrollPosition = ScrollPosition()
    @State private var settledItems: [ChatMessage] = []
    @State private var scrollTask: Task<Void, Never>?
    /// Separate handle from `scrollTask`. Owns the fade-in / scroll-on-switch
    /// sequence so a concurrent content-growth `scrollToBottomDebounced()`
    /// (which also writes to `scrollTask`) can't cancel the session-ready flip.
    @State private var readyTask: Task<Void, Never>?
    @State private var anchor = AutoScrollAnchor()
    @State private var isSessionReady = false

    private static let log = Logger(subsystem: "com.claudework", category: "MessageListView")

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                messageRows(settledItems[...])
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Streaming view is outside VStack — text deltas don't affect settled layout
            VStack(spacing: 16) {
                if !windowState.focusMode {
                    StreamingMessageView {
                        rebuildSettledItems()
                        if anchor.isNearBottom { scrollToBottomDebounced() }
                    }
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
                }

                if !chatBridge.isStreaming && !settledItems.isEmpty {
                    WebPreviewButton(messages: settledItems)
                        .id("web-preview")
                }
            }
            .padding(.horizontal, 20)
            // Suppress layout animations when switching sessions so the pulse indicator
            // doesn't visually jump as StreamingMessageView changes height.
            .animation(.none, value: windowState.currentSessionId)

            Color.clear.frame(height: 1)
                .padding(.bottom, 16)
        }
        .opacity(isSessionReady ? 1 : 0)
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: ScrollSample.self) { geo in
            ScrollSample(contentHeight: geo.contentSize.height, visibleMaxY: geo.visibleRect.maxY)
        } action: { _, sample in
            // Route the geometry change through AutoScrollAnchor so content
            // growth (e.g. an Edit/Bash card expanding) doesn't un-stick the
            // anchor — only deliberate user scrolling does. When growth
            // happened while anchored, the anchor asks us to scroll.
            let decision = anchor.apply(contentHeight: sample.contentHeight, visibleMaxY: sample.visibleMaxY)
            if decision == .scrollToBottom {
                scrollToBottomDebounced()
            }
        }
        .task(id: windowState.currentSessionId) {
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
                if !isSessionReady { isSessionReady = true }
                Self.log.info("[MessageList.task] streaming-path settled=\(settledItems.count) sid=\(sid, privacy: .public)")
                return
            }
            isSessionReady = false
            scrollTask?.cancel()
            readyTask?.cancel()
            scrollPosition = ScrollPosition()
            rebuildSettledItems()
            Self.log.info("[MessageList.task] post-rebuild settled=\(settledItems.count) sid=\(sid, privacy: .public) isLoadingFromDisk=\(chatBridge.isLoadingFromDisk)")
            // Skip scroll/fade delay for empty sessions — appear instantly,
            // unless we're still loading persisted messages from disk (in which
            // case the onChange handler below will fade the list in once messages
            // arrive, avoiding the empty → populated "blink").
            guard !settledItems.isEmpty else {
                if !chatBridge.isLoadingFromDisk {
                    isSessionReady = true
                    Self.log.info("[MessageList.task] empty + not-loading → ready sid=\(sid, privacy: .public)")
                } else {
                    Self.log.info("[MessageList.task] empty + still-loading → waiting for disk sid=\(sid, privacy: .public)")
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(16))  // 1 frame: scroll after VStack layout is committed
            scrollPosition.scrollTo(edge: .bottom)
            // Pre-set isNearBottom so streaming messages that arrive before onScrollGeometryChange
            // fires still trigger scrollToBottomDebounced(), keeping the pulse pinned to the bottom.
            anchor.resetToBottom()
            try? await Task.sleep(for: .milliseconds(32))  // 2 frames: fade-in after scroll settles
            withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
        }
        .onChange(of: chatBridge.isLoadingFromDisk) { _, isLoading in
            let sid = windowState.currentSessionId ?? "<nil>"
            Self.log.info("[MessageList.onLoadChange] isLoading=\(isLoading) sid=\(sid, privacy: .public) bridgeMessages=\(chatBridge.messages.count) settled=\(settledItems.count)")
            // When a background disk load finishes for a freshly switched session,
            // rebuild the settled list and fade in — same sequence as the .task above.
            // Rebuild regardless of `isSessionReady`: there is a race where .task
            // observes a stale `isLoadingFromDisk == false` (bridge observation
            // hasn't propagated yet), sets `isSessionReady = true` via the empty
            // early-exit, and then this handler would otherwise skip the rebuild,
            // leaving settled items empty even after messages load.
            guard !isLoading else { return }
            rebuildSettledItems()
            Self.log.info("[MessageList.onLoadChange] post-rebuild settled=\(settledItems.count) sid=\(sid, privacy: .public)")
            // Fade-in lives on `readyTask` so the content-growth path
            // (`scrollToBottomDebounced`, which owns `scrollTask`) cannot cancel it.
            readyTask?.cancel()
            readyTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                scrollPosition.scrollTo(edge: .bottom)
                anchor.resetToBottom()
                guard !isSessionReady else { return }
                try? await Task.sleep(for: .milliseconds(32))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
            }
        }
        .onChange(of: chatBridge.isStreaming) { old, new in
            // Only update when streaming ends — settled list doesn't change at start, so skip
            if old && !new {
                rebuildSettledItems()
                scrollToBottomDebounced()
            }
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

    // MARK: - Helpers

    @ViewBuilder
    private func messageRows(_ messages: some RandomAccessCollection<ChatMessage>) -> some View {
        let groups = groupMessages(Array(messages))
        ForEach(groups) { group in
            if group.isTransientGroup {
                TransientGroupSummaryView(messages: group.messages)
                    .id(group.id)
                    .transition(messageFadeTransition(role: .assistant))
            } else if let message = group.messages.first {
                MessageBubble(message: message)
                    .id(message.id)
                    .transition(messageFadeTransition(role: message.role))
            }
        }
    }

    private func messageFadeTransition(role: Role) -> AnyTransition {
        let anchor: UnitPoint = role == .user ? .bottomTrailing : .bottomLeading
        return .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
    }

    // MARK: - Message Grouping

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
            let boundary = streamingBoundaryIndex(in: messages)
            settled = Array(messages[..<boundary]).filter { !$0.isStreaming }
        } else {
            settled = messages.filter { !$0.isStreaming }
        }
        if windowState.focusMode {
            settled = settled.filter { $0.role == .user || $0.isResponseComplete || $0.isCompactBoundary }
        }
        return suppressPlanReadyFollowups(in: settled)
    }

    private func scrollToBottomDebounced() {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}

// MARK: - Message Grouping Helpers

/// Single-pass partition of messages into (settled, streaming) without scanning the array twice.
fileprivate func partitionByStreaming(_ messages: [ChatMessage]) -> (settled: [ChatMessage], streaming: [ChatMessage]) {
    var settled: [ChatMessage] = []
    var streaming: [ChatMessage] = []
    for m in messages { if m.isStreaming { streaming.append(m) } else { settled.append(m) } }
    return (settled, streaming)
}


fileprivate struct MessageGroup: Identifiable {
    let id: UUID
    let messages: [ChatMessage]
    let isTransientGroup: Bool
}

/// Returns true if the message would render only a transient tool summary (no visible text or non-transient tools).
fileprivate func isPureTransientMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary else { return false }
    // Whitespace-only text is treated as invisible so it doesn't break transient grouping.
    let hasVisibleText = message.blocks.contains {
        guard let text = $0.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if hasVisibleText { return false }
    let toolCalls = message.blocks.compactMap(\.toolCall)
    guard !toolCalls.isEmpty else { return false }
    let hasNonTransient = toolCalls.contains { !ToolCategory(toolName: $0.name).isTransient }
    if hasNonTransient { return false }
    return true
}

/// Returns true if the message has no renderable content — all tool calls were removed
/// (e.g. empty bash output stripped by setToolResult) and there is no text.
/// These messages are invisible in the UI and should not break transient-tool grouping.
fileprivate func isInvisibleMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary, !message.isStreaming else { return false }
    return message.blocks.isEmpty
}

fileprivate func suppressPlanReadyFollowups(in messages: [ChatMessage]) -> [ChatMessage] {
    var result: [ChatMessage] = []
    var assistantRun: [ChatMessage] = []

    func flushAssistantRun() {
        guard !assistantRun.isEmpty else { return }
        let hasExitPlan = assistantRun.contains { PlanLogic.containsExitPlanMode($0) }
        var hasRecentPlanCard = false

        for message in assistantRun {
            if hasExitPlan && PlanLogic.isPurePlanFileWriteMessage(message) {
                continue
            }

            // Plan-ready follow-up messages (e.g. "Plan is ready at /…/plans/foo.md")
            // are intentionally kept visible alongside the plan card so the user
            // sees the summary while approval is pending.
            _ = hasRecentPlanCard

            if PlanLogic.containsExitPlanMode(message) {
                hasRecentPlanCard = true
            }
            result.append(message)
        }

        assistantRun.removeAll(keepingCapacity: true)
    }

    for message in messages {
        if message.role == .user {
            flushAssistantRun()
            result.append(message)
            continue
        }

        assistantRun.append(message)
    }
    flushAssistantRun()

    return result
}

fileprivate func isPlanReadyFollowupMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant,
          !message.isError,
          !message.isCompactBoundary,
          !message.isStreaming,
          !message.blocks.isEmpty else {
        return false
    }
    return message.blocks.allSatisfy { block in
        guard let text = block.text else { return false }
        return PlanLogic.isPlanReadyFollowup(text)
    }
}

/// Groups consecutive pure-transient assistant messages into combined groups.
/// - Parameter minGroupSize: Minimum number of transient messages required to collapse into a group.
///   Pass 1 (streaming context) to hide even a single completed tool call the moment the next message starts.
///   Pass 2 (settled list) to keep lone tool calls visible after streaming ends.
fileprivate func groupMessages(_ messages: [ChatMessage], minGroupSize: Int = 2) -> [MessageGroup] {
    var result: [MessageGroup] = []
    var accumulator: [ChatMessage] = []

    func flushAccumulator() {
        guard !accumulator.isEmpty else { return }
        if accumulator.count >= minGroupSize {
            result.append(MessageGroup(id: accumulator[0].id, messages: accumulator, isTransientGroup: true))
        } else {
            for m in accumulator {
                result.append(MessageGroup(id: m.id, messages: [m], isTransientGroup: false))
            }
        }
        accumulator = []
    }

    for message in messages {
        if isPureTransientMessage(message) {
            accumulator.append(message)
        } else if isInvisibleMessage(message) {
            // Skip invisible messages (e.g. all tool calls removed due to empty results).
            // They render nothing in the UI and must not break consecutive transient grouping.
            continue
        } else {
            flushAccumulator()
            result.append(MessageGroup(id: message.id, messages: [message], isTransientGroup: false))
        }
    }
    flushAccumulator()

    return result
}

// MARK: - Shared Helper

/// Returns the start index of the last consecutive non-error assistant sequence.
/// Used to distinguish the settled (previous) / active (streaming) boundary.
private func streamingBoundaryIndex(in messages: [ChatMessage]) -> Int {
    var idx = messages.count - 1
    while idx >= 0 && messages[idx].role == .assistant && !messages[idx].isError {
        idx -= 1
    }
    return idx + 1
}

// MARK: - Streaming Message (isolated view — chatBridge.messages dependency confined to this view)

struct StreamingMessageView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    var onStructureChanged: () -> Void

    var body: some View {
        let messages = chatBridge.messages
        let activeMessages = activeResponseMessages(from: messages)
        let (settledActive, streamingActive) = partitionByStreaming(activeMessages)
        Group {
            if !activeMessages.isEmpty {

                if !streamingActive.isEmpty {
                    // Collapse completed transient tool calls (even a single one) the moment
                    // the next streaming message begins, so only the current message stays visible.
                    let groups = groupMessages(settledActive, minGroupSize: 1)
                    ForEach(groups) { group in
                        if group.isTransientGroup {
                            TransientGroupSummaryView(messages: group.messages)
                                .id(group.id)
                                .transition(streamFadeTransition(role: .assistant))
                        } else if let message = group.messages.first {
                            MessageBubble(message: message)
                                .id(message.id)
                                .transition(streamFadeTransition(role: message.role))
                        }
                    }
                } else {
                    // Nothing streaming yet — show each settled message individually.
                    ForEach(settledActive, id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .transition(streamFadeTransition(role: message.role))
                    }
                }

                ForEach(streamingActive, id: \.id) { message in
                    MessageBubble(message: message)
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
        return suppressPlanReadyFollowups(in: Array(messages[streamingBoundaryIndex(in: messages)...]))
    }
}

// MARK: - Transient Group Summary

struct TransientGroupSummaryView: View {
    let messages: [ChatMessage]
    @State private var isExpanded = false

    private var allToolCalls: [ToolCall] {
        messages.flatMap { $0.blocks.compactMap(\.toolCall) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text(String(format: String(localized: "%lld tools executed", bundle: .module), allToolCalls.count))
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.size(9)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(allToolCalls, id: \.id) { toolCall in
                        ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                    }
                }
            }
            Spacer(minLength: 40)
        }
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
