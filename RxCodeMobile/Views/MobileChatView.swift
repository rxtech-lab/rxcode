import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Read-write chat view. User messages are forwarded to the desktop and the
/// desktop agent's stream is mirrored back as `session_update` payloads.
struct MobileChatView: View {
    @EnvironmentObject private var state: MobileAppState
    let sessionID: String
    /// Invoked after the thread is archived or deleted so the parent can pop
    /// this view — the thread is no longer reachable from the active list.
    var onClose: () -> Void = {}
    @State private var composer: String = ""
    @State private var isNearBottom: Bool = true
    @State private var showingQueueSheet = false
    @State private var didEstablishInitialScroll = false
    @State private var showingRenameSheet = false
    @State private var showingArchiveConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingTodoSheet = false
    /// The question request whose sheet is currently presented, if any.
    @State private var presentedQuestion: PendingQuestionPayload?
    /// The plan whose review sheet is currently presented, if any.
    @State private var presentedPlan: PendingPlan?
    /// The message that sat at the top before an older page was requested. The
    /// viewport is restored to it after the page is prepended so the content
    /// the user was reading doesn't jump.
    @State private var pendingTopAnchorID: UUID?
    /// Gates the scroll-up "load more" trigger until the initial scroll-to-
    /// bottom has settled, so opening a thread doesn't immediately page back.
    @State private var didSettleInitialScroll = false
    /// True while the user is actively driving the scroll view (dragging or
    /// momentum). Layout- and keyboard-induced offset shifts happen outside
    /// these phases and must not be mistaken for a deliberate scroll-up.
    @State private var isUserDragging = false
    /// While `false`, the stream no longer pulls the viewport to the bottom —
    /// set when the user scrolls up so they can read history without being
    /// yanked back down. Re-armed once they return to the bottom.
    @State private var autoScrollEnabled = true

    private static let bottomAnchorID = "message-list-bottom"
    private static let bottomContentPadding: CGFloat = 200
    /// Distance from the bottom past which the "scroll to bottom" button shows.
    private static let nearBottomThreshold: CGFloat = 120
    /// Distance from the true bottom within which auto-follow re-arms. Kept
    /// small on purpose: the bottom is always reachable regardless of thread
    /// length, so this works even for threads barely taller than the viewport.
    private static let atBottomThreshold: CGFloat = 16
    /// Minimum upward scroll delta (points) that counts as the user
    /// deliberately leaving the bottom.
    private static let userScrollUpDelta: CGFloat = 4
    /// Load older messages once the viewport scrolls within this many points
    /// of the top.
    private static let loadMoreThreshold: CGFloat = 150

    var body: some View {
        activeThreadLayout
            .animation(.easeInOut(duration: 0.2), value: queuedMessages.count)
            .animation(.easeInOut(duration: 0.2), value: sessionQuestions.count)
            .animation(.easeInOut(duration: 0.2), value: pendingPlans.count)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(title)
            .toolbar { threadActionsToolbar }
            .sheet(isPresented: $showingQueueSheet) {
                QueuedMessagesSheet(
                    messages: queuedMessages,
                    onRemove: removeQueued
                )
            }
            .sheet(isPresented: $showingRenameSheet) {
                RenameThreadSheet(currentTitle: title) { newTitle in
                    Task { await state.renameThread(sessionID: sessionID, title: newTitle) }
                }
            }
            .sheet(isPresented: $showingTodoSheet) {
                ThreadTodoSheet(
                    threadTitle: title,
                    todos: todos ?? [],
                    summary: threadSummary
                )
            }
            .sheet(item: $presentedQuestion) { question in
                MobileQuestionSheet(
                    request: question,
                    remainingCount: max(0, sessionQuestions.count - 1),
                    onSubmit: { answers in
                        Task { await state.answerQuestion(toolUseID: question.toolUseID, answers: answers) }
                    },
                    onSkipAll: {
                        Task { await state.skipQuestion(toolUseID: question.toolUseID) }
                    }
                )
            }
            .onChange(of: sessionQuestions) { _, questions in
                // A question resolved elsewhere (desktop or another device)
                // should close a now-stale sheet.
                if let presented = presentedQuestion,
                   !questions.contains(where: { $0.toolUseID == presented.toolUseID })
                {
                    presentedQuestion = nil
                }
            }
            .sheet(item: $presentedPlan) { plan in
                PlanSheetView(
                    plan: plan,
                    remainingCount: max(0, pendingPlans.count - 1),
                    onSubmit: { toolCallID, action in
                        Task {
                            await state.respondToPlanDecision(
                                toolUseID: toolCallID,
                                sessionID: sessionID,
                                action: action
                            )
                        }
                        presentedPlan = nil
                    },
                    onClose: { presentedPlan = nil }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: sessionPlans) { _, plans in
                // The plan resolved (decided here or on another device) or
                // vanished — close the now-stale sheet.
                guard let presented = presentedPlan else { return }
                let stillPending = plans.contains {
                    $0.toolCallId == presented.toolCallId && !$0.isDecided
                }
                if !stillPending { presentedPlan = nil }
            }
            .confirmationDialog(
                "Archive this thread?",
                isPresented: $showingArchiveConfirm,
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) { performArchive() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Archived threads are hidden from the list. You can still find them on your Mac.")
            }
            .confirmationDialog(
                "Delete this thread?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the thread and all of its messages. This cannot be undone.")
            }
    }

    // MARK: - Thread actions toolbar

    @ToolbarContentBuilder
    private var threadActionsToolbar: some ToolbarContent {
        if threadExists {
            ToolbarItem(placement: .principal) {
                navigationTitleView
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingRenameSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        showingArchiveConfirm = true
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Thread actions")
            }
        }
    }

    /// Tappable navigation-title view. Tapping always opens the todo + summary
    /// sheet so the thread summary stays reachable. When the thread has todos
    /// it also shows a progress indicator; otherwise a subtle chevron hints
    /// that the title is interactive. Mirrors the desktop's todo progress pill.
    @ViewBuilder
    private var navigationTitleView: some View {
        let todos = self.todos
        Button {
            showingTodoSheet = true
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let todos, !todos.isEmpty {
                    let done = todos.filter { $0.status == .completed }.count
                    let inProgress = todos.contains { $0.status == .inProgress }
                    MobileTodoProgressIndicator(
                        done: done,
                        total: todos.count,
                        inProgress: inProgress
                    )
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(navigationTitleAccessibilityLabel)
        .accessibilityHint("Opens todos and thread summary")
    }

    private var navigationTitleAccessibilityLabel: String {
        guard let todos, !todos.isEmpty else {
            return "\(title). Tap to view thread summary."
        }
        let done = todos.filter { $0.status == .completed }.count
        return "\(title). Todos, \(done) of \(todos.count) complete. Tap to view todos and thread summary."
    }

    /// A real, persisted thread the desktop can act on — excludes drafts.
    private var threadExists: Bool {
        !MobileDraftSessionID.isDraft(sessionID)
            && state.sessions.contains(where: { $0.id == sessionID })
    }

    private func performArchive() {
        Task { await state.archiveThread(sessionID: sessionID) }
        onClose()
    }

    private func performDelete() {
        Task { await state.deleteThread(sessionID: sessionID) }
        onClose()
    }

    // MARK: - Active Thread Layout

    private var activeThreadLayout: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if isLoadingMore {
                            loadMoreSpinner
                        }
                        ChatMessageListView(messages: messages)
                        if isStreaming {
                            MobileStreamingIndicator(isThinking: isThinking)
                                .transition(.opacity)
                        }
                        Color.clear
                            .frame(height: Self.bottomContentPadding)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .animation(.easeInOut(duration: 0.2), value: isStreaming)
                    .animation(.easeInOut(duration: 0.2), value: isLoadingMore)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, newPhase, _ in
                    isUserDragging = newPhase == .tracking
                        || newPhase == .interacting
                        || newPhase == .decelerating
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentSize.height - geo.visibleRect.maxY
                } action: { _, distanceFromBottom in
                    let near = distanceFromBottom <= Self.nearBottomThreshold
                    if isNearBottom != near { isNearBottom = near }
                    // Returning to the true bottom re-arms auto-follow.
                    if distanceFromBottom <= Self.atBottomThreshold {
                        autoScrollEnabled = true
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { oldOffsetY, offsetY in
                    // A deliberate upward drag means the user wants to read
                    // history — stop the stream from pulling them back down.
                    // Gated on `isUserDragging` so keyboard/layout-induced
                    // offset shifts don't disable auto-follow.
                    if isUserDragging, offsetY < oldOffsetY - Self.userScrollUpDelta {
                        autoScrollEnabled = false
                    }
                    if offsetY < Self.loadMoreThreshold { triggerLoadMoreIfNeeded() }
                }
                .onAppear {
                    if !didEstablishInitialScroll {
                        didEstablishInitialScroll = true
                    }
                }
                .task {
                    // Let the initial scroll-to-bottom settle before arming the
                    // scroll-up "load more" trigger, so opening a thread doesn't
                    // immediately page in older history.
                    try? await Task.sleep(for: .seconds(0.8))
                    didSettleInitialScroll = true
                }
                .onChange(of: messages.last?.id) { _, _ in
                    // Keyed on the last message id so a prepended older page
                    // (which leaves the tail unchanged) doesn't yank to bottom.
                    guard didEstablishInitialScroll else {
                        didEstablishInitialScroll = true
                        return
                    }
                    guard autoScrollEnabled else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: messages.last?.content) { _, _ in
                    guard didEstablishInitialScroll, autoScrollEnabled else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: isStreaming) { _, streaming in
                    // Keep the newly appeared loading indicator in view.
                    guard streaming, didEstablishInitialScroll, autoScrollEnabled else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: isLoadingMore) { _, loading in
                    // An older page finished loading: restore the viewport to
                    // the message that was on top so the prepend isn't jarring.
                    guard !loading, let anchor = pendingTopAnchorID else { return }
                    pendingTopAnchorID = nil
                    proxy.scrollTo(anchor, anchor: .top)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isNearBottom {
                        scrollToBottomButton(proxy: proxy)
                            .padding(.trailing, 16)
                            .padding(.bottom, 80)
                            .transition(.scale.combined(with: .opacity))
                            .zIndex(1)
                    }
                }
                .animation(.spring(duration: 0.25), value: isNearBottom)
            }

            VStack(spacing: 0) {
                if !queuedMessages.isEmpty {
                    queuedPreviewPill
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !sessionQuestions.isEmpty {
                    questionQueueBanner
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !pendingPlans.isEmpty {
                    planBanner
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                MobileInputBar(
                    text: $composer,
                    isStreaming: isStreaming,
                    onSend: handleSend,
                    onStop: handleStop
                )
            }
            .background(Color.clear)
            .zIndex(2)
        }
    }

    private var messages: [ChatMessage] {
        state.messagesBySession[sessionID] ?? []
    }

    private var title: String {
        state.sessions.first(where: { $0.id == sessionID })?.title ?? "Thread"
    }

    /// Live todos extracted from the most recent `TodoWrite` tool call in the
    /// thread's messages — the same source the desktop toolbar pill uses.
    /// `nil` when the thread has never emitted a todo list.
    private var todos: [TodoItem]? {
        TodoExtractor.latest(in: messages)
    }

    /// The desktop-generated summary for this thread, if one exists. Summaries
    /// are produced once a thread finishes a turn, so live threads may not have
    /// one yet.
    private var threadSummary: MobileThreadSummary? {
        state.threadSummaries.first { $0.sessionId == sessionID }
    }

    private var isStreaming: Bool {
        state.isSessionStreaming(sessionID)
    }

    private var isThinking: Bool {
        state.isSessionThinking(sessionID)
    }

    private var isLoadingMore: Bool {
        state.isLoadingMoreMessages(sessionID: sessionID)
    }

    private var queuedMessages: [QueuedUserMessage] {
        state.queuedMessages(sessionID: sessionID)
    }

    /// `AskUserQuestion` calls awaiting an answer for this thread.
    private var sessionQuestions: [PendingQuestionPayload] {
        state.pendingQuestions(sessionID: sessionID)
    }

    /// Every plan card for this thread (pending + decided), derived from the
    /// synced messages via the shared `PlanLogic`.
    private var sessionPlans: [PendingPlan] {
        state.pendingPlans(sessionID: sessionID)
    }

    /// Plans still awaiting a decision — what the plan banner surfaces.
    private var pendingPlans: [PendingPlan] {
        sessionPlans.filter { !$0.isDecided && !$0.isStreaming }
    }

    // MARK: - Message paging

    /// Spinner shown at the top of the list while an older page is loading.
    private var loadMoreSpinner: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    /// Request the next older page when the user scrolls near the top. Captures
    /// the current top message so the viewport can be restored after the page
    /// is prepended. `pendingTopAnchorID` doubles as an in-flight guard.
    private func triggerLoadMoreIfNeeded() {
        guard didSettleInitialScroll,
              pendingTopAnchorID == nil,
              state.hasMoreMessages(sessionID: sessionID),
              !state.isLoadingMoreMessages(sessionID: sessionID),
              let anchor = messages.first?.id
        else { return }
        pendingTopAnchorID = anchor
        Task {
            let dispatched = await state.loadMoreMessages(sessionID: sessionID)
            // Nothing was sent (e.g. not paired) — clear the guard so a later
            // scroll can retry.
            if !dispatched { pendingTopAnchorID = nil }
        }
    }

    // MARK: - Send / Stop

    private func handleSend(_ trimmed: String) {
        // Sending always returns the user's focus to the latest messages.
        autoScrollEnabled = true
        Task {
            await state.sendUserMessage(trimmed, sessionID: sessionID)
            composer = ""
        }
    }

    private func handleStop() {
        guard !sessionID.isEmpty else { return }
        Task { await state.cancelStream(sessionID: sessionID) }
    }

    private func removeQueued(_ queued: QueuedUserMessage) {
        Task { await state.removeQueuedMessage(sessionID: sessionID, queuedID: queued.id) }
    }

    // MARK: - Scroll to bottom button

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            autoScrollEnabled = true
            withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                )
                .overlay(
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to bottom")
    }

    // MARK: - Queued preview pill

    private var queuedPreviewPill: some View {
        Button {
            showingQueueSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(queuedMessages.count) queued")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let first = queuedMessages.first {
                        Text(first.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(queuedMessages.count) queued messages. Tap to view all.")
    }

    // MARK: - Question queue banner

    /// Compact pill shown directly above the input bar whenever the agent has
    /// `AskUserQuestion` calls awaiting an answer. Tapping it opens the question
    /// sheet for the first queued request — mirrors the desktop banner.
    private var questionQueueBanner: some View {
        Button {
            presentedQuestion = sessionQuestions.first
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)

                Text(questionBannerText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer(minLength: 8)

                Text("Answer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.accent, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClaudeTheme.accentSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ClaudeTheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(questionBannerText). Tap to answer.")
    }

    private var questionBannerText: String {
        let count = sessionQuestions.count
        return count == 1 ? "1 question pending" : "\(count) questions pending"
    }

    // MARK: - Plan review banner

    /// Compact pill above the input bar shown whenever the agent has produced a
    /// plan awaiting a decision. Tapping it opens the shared `PlanSheetView` —
    /// the same review/accept/modify component the desktop uses.
    private var planBanner: some View {
        Button {
            presentedPlan = pendingPlans.first
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)

                Text(planBannerText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer(minLength: 8)

                Text("Review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.accent, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(ClaudeTheme.accent).interactive(), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(planBannerText). Tap to review.")
    }

    private var planBannerText: String {
        let count = pendingPlans.count
        return count == 1 ? "Plan ready to review" : "\(count) plans ready to review"
    }
}

// MARK: - Streaming Indicator

/// Loading indicator shown at the end of the message list while the agent is
/// generating a response — mirrors the desktop `StreamingIndicatorView`. Shows
/// a "Thinking…" label while the agent is producing reasoning tokens, and three
/// bouncing dots throughout.
private struct MobileStreamingIndicator: View {
    var isThinking: Bool = false
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isThinking {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Thinking")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .transition(.opacity)
            }
            dots
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityLabel(isThinking ? "Thinking" : "Response in progress")
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(ClaudeTheme.textTertiary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .scaleEffect(phase == i ? 1.0 : 0.85)
                    .animation(.easeInOut(duration: 0.25), value: phase)
            }
        }
    }
}

// MARK: - Rename Thread Sheet

/// Compact modal that captures a new thread title. Commits the trimmed value
/// via `onSubmit` and dismisses; an empty title is treated as a no-op.
private struct RenameThreadSheet: View {
    let currentTitle: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(currentTitle: String, onSubmit: @escaping (String) -> Void) {
        self.currentTitle = currentTitle
        self.onSubmit = onSubmit
        _text = State(initialValue: currentTitle)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != currentTitle
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thread name") {
                    TextField("Thread name", text: $text)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                }
            }
            .navigationTitle("Rename Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isFocused = true
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func commit() {
        guard canSave else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

// MARK: - Queued Messages Sheet

private struct QueuedMessagesSheet: View {
    let messages: [QueuedUserMessage]
    let onRemove: (QueuedUserMessage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "No Queued Messages",
                        systemImage: "tray",
                        description: Text("Messages you queue while a response is streaming appear here.")
                    )
                } else {
                    List {
                        ForEach(messages) { queued in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(queued.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onRemove(queued)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Queued Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Todo Progress Indicator

/// Compact progress ring shown beside the navigation title while a thread has
/// todos. Mirrors the desktop `TodoProgressPill`: a determinate ring filling as
/// todos complete, accented while work is in progress and green once done.
private struct MobileTodoProgressIndicator: View {
    let done: Int
    let total: Int
    let inProgress: Bool

    private var isComplete: Bool { total > 0 && done == total }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    private var accent: Color {
        if isComplete { return ClaudeTheme.statusSuccess }
        if inProgress { return ClaudeTheme.accent }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(accent.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: fraction)
            }
            .frame(width: 15, height: 15)

            Text("\(done)/\(total)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .contentShape(Capsule())
    }
}

// MARK: - Thread Todo Sheet

/// Bottom sheet listing the thread's todo items and its generated summary,
/// mirroring the desktop's todo popover. Opened from the navigation-title
/// progress indicator.
private struct ThreadTodoSheet: View {
    let threadTitle: String
    let todos: [TodoItem]
    let summary: MobileThreadSummary?
    @Environment(\.dismiss) private var dismiss

    private var doneCount: Int {
        todos.filter { $0.status == .completed }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleHeader
                    if !todos.isEmpty {
                        todoSection
                    }
                    summarySection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(todos.isEmpty ? "Thread Summary" : "Todos & Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Title header

    private var titleHeader: some View {
        Text(threadTitle)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Todo section

    @ViewBuilder
    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Todos")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(doneCount)/\(todos.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if todos.isEmpty {
                Text("No todos for this thread.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(todos) { todo in
                        todoRow(todo)
                    }
                }
            }
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(todo.status)
                .font(.system(size: 17))
                .frame(width: 22)
            Text(label(for: todo))
                .font(.callout)
                .foregroundStyle(textColor(todo.status))
                .strikethrough(todo.status == .completed, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: TodoItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .inProgress:
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(ClaudeTheme.accent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusSuccess)
        }
    }

    private func label(for todo: TodoItem) -> String {
        todo.status == .inProgress && !todo.activeForm.isEmpty ? todo.activeForm : todo.content
    }

    private func textColor(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .primary
        case .completed: return .secondary
        }
    }

    // MARK: Summary section

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            if let summary, !summary.summary.isEmpty {
                ChatTextContentView(
                    markdown: summary.summary,
                    size: 15,
                    color: .primary,
                    lineSpacing: 3
                )
            } else {
                Text("No summary yet. A summary is generated once the thread finishes a turn on your Mac.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
