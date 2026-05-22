import Combine
import OSLog
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

private let mobileChatLogger = Logger(
    subsystem: "com.idealapp.RxCodeMobile",
    category: "MobileChat"
)

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
    /// Set once the thread has been scrolled to its newest message on open.
    /// Until then, an arriving message jumps to the bottom without animation;
    /// after, message updates animate as the streaming follow.
    @State private var didEstablishInitialScroll = false
    @State private var showingRenameSheet = false
    @State private var showingArchiveConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingTodoSheet = false
    @State private var showingRunProfiles = false
    @State private var showingBrowser = false
    @State private var showingChanges = false
    /// The question request whose sheet is currently presented, if any.
    @State private var presentedQuestion: PendingQuestionPayload?
    /// The plan whose review sheet is currently presented, if any.
    @State private var presentedPlan: PendingPlan?
    /// The message that sat at the top before an older page was requested. The
    /// viewport is restored to it after the page is prepended so the content
    /// the user was reading doesn't jump.
    @State private var pendingTopAnchorID: UUID?
    /// Re-asserts the preserved position after SwiftUI has laid out a prepended
    /// page. A single `scrollTo` can fire before the lazy stack has realized the
    /// old anchor row.
    @State private var loadMoreRestoreTask: Task<Void, Never>?
    /// Re-asserts the just-sent message pin while lazy row geometry, dynamic
    /// spacer height, and keyboard-driven composer movement settle.
    @State private var pinToTopTask: Task<Void, Never>?
    /// Re-asserts the first scroll-to-bottom while the lazy stack and composer
    /// geometry settle on thread entry.
    @State private var initialScrollTask: Task<Void, Never>?
    /// Prevents repeated scheduling while the delayed initial scroll is
    /// waiting for the first loaded page to finish laying out.
    @State private var isEstablishingInitialScroll = false
    /// Hides the thread while the initial delayed scroll is pending, avoiding
    /// a visible flash at the top before the view lands on the latest message.
    @State private var isInitialMessageListHidden = true
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
    /// Full height of the scroll view (independent of the keyboard).
    @State private var scrollViewHeight: CGFloat = 0
    /// Global `minY` of the scroll view.
    @State private var scrollViewMinY: CGFloat = 0
    /// Global `minY` of the floating composer stack — its top is the boundary
    /// between the visible chat area and the area covered by composer + keyboard.
    @State private var composerMinY: CGFloat = 0
    /// `minY` of the latest user message in `chatContentCoordinateSpace`.
    @State private var latestUserMinY: CGFloat = 0
    /// `minY` of the tail spacer in `chatContentCoordinateSpace`.
    @State private var tailSpacerMinY: CGFloat = 0
    /// Set by `handleSend`; the next appended user message is the one we sent
    /// and should be pinned to the top of the viewport.
    @State private var awaitingSentUserMessage = false
    /// User message for the active turn. Its trailing spacer persists even
    /// after manual scroll and shrinks as the assistant response fills in.
    @State private var activeTurnUserMessageID: UUID?
    /// Immediate spacer reduction used while SwiftUI has not yet reported the
    /// streaming indicator's new tail geometry.
    @State private var pendingIndicatorSpacerReduction: CGFloat = 0
    /// True only for the active send flow where the just-sent user message is
    /// actively kept at the top while layout and keyboard geometry settle.
    @State private var isPinningLatestTurnToTop = false
    /// Prevents stale/user scroll phase callbacks from immediately canceling a
    /// new programmatic top-pin before it has settled.
    @State private var canReleasePinnedTurnByScroll = false
    @State private var distanceFromBottom: CGFloat = 0
    @State private var minimumThreadLoadElapsed = false
    @State private var isThreadLoadingOverlayVisible = true
    @State private var threadLoadingHideTask: Task<Void, Never>?

    private static let bottomAnchorID = "message-list-bottom"
    private static let endOfScreenAnchorID = "message-list-end-of-screen"
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
    /// Approximate indicator height plus LazyVStack spacing. Cleared once the
    /// tail marker reports the indicator in measured geometry.
    private static let streamingIndicatorEstimatedHeight: CGFloat = 36

    var body: some View {
        activeThreadLayout
            .animation(.easeInOut(duration: 0.2), value: queuedMessages.count)
            .animation(.easeInOut(duration: 0.2), value: sessionQuestions.count)
            .animation(.easeInOut(duration: 0.2), value: pendingPlans.count)
            .animation(.easeInOut(duration: 0.25), value: shouldShowThreadLoading)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(title)
            .toolbar { threadActionsToolbar }
            .task(id: sessionID) {
                await runThreadLoadingGate()
            }
            .onChange(of: isThreadLoadingMessages) { _, isLoading in
                handleThreadLoadingChange(isLoading)
            }
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
            .sheet(isPresented: $showingRunProfiles) {
                if let projectID = currentProjectID {
                    NavigationStack {
                        MobileRunProfilesView(projectID: projectID)
                            .environmentObject(state)
                            .task {
                                await state.refreshFromDesktop(reason: "open_run_profiles")
                            }
                    }
                }
            }
            .sheet(isPresented: $showingChanges) {
                ThreadChangesSheet(sessionID: sessionID)
                    .environmentObject(state)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showingBrowser) {
                NavigationStack {
                    MobileInAppBrowserView(
                        initialURL: browserLaunchURL,
                        proxyInfo: state.desktopWebProxy
                    )
                }
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
                        showingBrowser = true
                    } label: {
                        Label("Open in Browser", systemImage: "globe")
                    }
                    Button {
                        showingRunProfiles = true
                    } label: {
                        Label("Run Profiles", systemImage: "play.rectangle")
                    }
                    .disabled(currentProjectID == nil)
                    Button {
                        showingChanges = true
                    } label: {
                        Label("View Changes", systemImage: "plus.forwardslash.minus")
                    }
                    Divider()
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
                        // Extra tail spacer: pads the latest turn only while a
                        // freshly sent user message is pinned to the top, and
                        // shrinks as the assistant response grows.
                        Color.clear
                            .frame(height: pinTailSpacerExtraHeight)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .opacity(isInitialMessageListHidden && !messages.isEmpty ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isStreaming)
                    .animation(.easeInOut(duration: 0.2), value: isLoadingMore)
                    .animation(.easeInOut(duration: 0.18), value: isInitialMessageListHidden)
                    .coordinateSpace(.named(chatContentCoordinateSpace))
                    .environment(\.chatTrackedMessageID, trackedUserMessageID)
                    .environment(\.chatTrackedMessageGeometry, updateLatestUserMinY)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chat-message-list")
                }
                .accessibilityIdentifier("chat-screen")
                .mobileDismissesKeyboardOnScroll(.interactively)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { rect in
                    scrollViewHeight = rect.height
                    scrollViewMinY = rect.minY
                }
                .onScrollPhaseChange { _, newPhase, _ in
                    isUserDragging = newPhase == .tracking
                        || newPhase == .interacting
                        || newPhase == .decelerating
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentSize.height - geo.visibleRect.maxY
                } action: { _, distanceFromBottom in
                    self.distanceFromBottom = distanceFromBottom
                    let near = distanceFromBottom <= Self.nearBottomThreshold
                    if isNearBottom != near {
                        mobileChatLogger.debug(
                            "[ScrollButton] visibility near=\(near, privacy: .public) distance=\(Double(distanceFromBottom), privacy: .public)"
                        )
                        isNearBottom = near
                    }
                    // Returning to the true bottom re-arms auto-follow.
                    if distanceFromBottom <= Self.atBottomThreshold {
                        autoScrollEnabled = true
                        if isUserDragging {
                            isPinningLatestTurnToTop = false
                        }
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { oldOffsetY, offsetY in
                    if isUserDragging,
                       isPinningLatestTurnToTop,
                       canReleasePinnedTurnByScroll,
                       offsetY > oldOffsetY + Self.userScrollUpDelta
                    {
                        releasePinnedTurnToBottom(proxy: proxy)
                    }
                    // A deliberate upward drag means the user wants to read
                    // history — stop the stream from pulling them back down.
                    // Gated on `isUserDragging` so keyboard/layout-induced
                    // offset shifts don't disable auto-follow.
                    if isUserDragging, offsetY < oldOffsetY - Self.userScrollUpDelta {
                        autoScrollEnabled = false
                    }
                    if isUserDragging, offsetY < Self.loadMoreThreshold {
                        triggerLoadMoreIfNeeded()
                    }
                }
                .onAppear {
                    // A cached thread already has its messages — jump straight
                    // to the newest one. Threads loaded async are handled by
                    // the `messages.last?.id` change below.
                    establishInitialScroll(proxy: proxy, reason: "onAppear")
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
                    // (which leaves the tail unchanged) doesn't yank the view.
                    guard let last = messages.last else { return }
                    if last.role == .user, awaitingSentUserMessage {
                        // The message we just sent round-tripped back from the
                        // desktop — pin it to the top of the viewport. Handle
                        // this before initial-scroll gating so the first
                        // message in an empty thread is pinned too.
                        awaitingSentUserMessage = false
                        autoScrollEnabled = false
                        activeTurnUserMessageID = last.id
                        isPinningLatestTurnToTop = true
                        initialScrollTask?.cancel()
                        isEstablishingInitialScroll = false
                        didEstablishInitialScroll = true
                        isInitialMessageListHidden = false
                        pinSentMessageToTop(last.id, proxy: proxy)
                    } else if !didEstablishInitialScroll {
                        // First page of messages arrived after the view
                        // appeared — jump straight to the newest one.
                        establishInitialScroll(proxy: proxy, reason: "messagesArrived")
                    } else if repinActiveTurnIfNeeded(proxy: proxy) {
                        return
                    } else if autoScrollEnabled {
                        withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                    }
                }
                .onChange(of: messages.last?.content) { _, _ in
                    guard didEstablishInitialScroll else { return }
                    if repinActiveTurnIfNeeded(proxy: proxy) { return }
                    guard autoScrollEnabled else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: isStreaming) { _, streaming in
                    // Keep the newly appeared loading indicator in view.
                    if !streaming {
                        pendingIndicatorSpacerReduction = 0
                    }
                    guard streaming, didEstablishInitialScroll else { return }
                    if activeTurnUserMessageID != nil {
                        pendingIndicatorSpacerReduction = Self.streamingIndicatorEstimatedHeight
                    }
                    if repinActiveTurnIfNeeded(proxy: proxy) { return }
                    guard autoScrollEnabled else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: isLoadingMore) { _, loading in
                    guard !loading, let anchor = pendingTopAnchorID else { return }
                    pendingTopAnchorID = nil
                    if autoScrollEnabled {
                        // The page was pulled in to fill a near-empty screen
                        // on open — keep the newest message in view instead of
                        // jumping up to the freshly prepended history.
                        settleScroll(proxy: proxy, to: Self.bottomAnchorID, anchor: .bottom)
                    } else {
                        // The user scrolled up to read history: restore the
                        // viewport to the message that was on top so the
                        // prepend isn't jarring.
                        settleScroll(proxy: proxy, to: anchor, anchor: .top)
                    }
                }
                .onChange(of: composerMinY) { oldValue, newValue in
                    handleComposerBoundaryChange(
                        oldValue: oldValue,
                        newValue: newValue,
                        proxy: proxy
                    )
                }
                .overlay(alignment: .bottomLeading) {
                    if !isNearBottom {
                        scrollToBottomButton(proxy: proxy)
                            .padding(.leading, 16)
                            .padding(.bottom, scrollToBottomButtonBottomPadding)
                            .transition(.scale.combined(with: .opacity))
                            .zIndex(1)
                            .onAppear {
                                mobileChatLogger.debug(
                                    "[ScrollButton] appeared bottomPadding=\(Double(scrollToBottomButtonBottomPadding), privacy: .public)"
                                )
                            }
                            .onDisappear {
                                mobileChatLogger.debug("[ScrollButton] disappeared")
                            }
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
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minY
            } action: { newValue in
                composerMinY = newValue
            }

            if shouldShowThreadLoading {
                MobileThreadLoadingOverlay()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity.combined(with: .move(edge: .bottom))
                        )
                    )
                    .zIndex(3)
            }
        }
    }

    private var messages: [ChatMessage] {
        state.messagesBySession[sessionID] ?? []
    }

    private var currentProjectID: UUID? {
        state.sessions.first(where: { $0.id == sessionID })?.projectId
    }

    private var browserLaunchURL: URL? {
        let threadURL = MobileBrowserURLDetector.detect(in: messages.map(\.content))
        if let threadURL { return threadURL }
        guard let projectID = currentProjectID else { return nil }
        let taskText = state.runTasks(for: projectID).flatMap { task in
            [task.commandPreview, task.terminalOutputTail ?? ""]
        }
        return MobileBrowserURLDetector.detect(in: taskText)
    }

    private var title: String {
        state.sessions.first(where: { $0.id == sessionID })?.title ?? "Thread"
    }

    /// Live todos from synced messages when available, otherwise from the
    /// desktop session summary. Codex plan updates arrive as desktop-owned
    /// snapshots rather than `TodoWrite` message tool calls.
    private var todos: [TodoItem]? {
        TodoExtractor.latest(in: messages)
            ?? state.sessions.first(where: { $0.id == sessionID })?.todos
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

    private var isThreadLoadingMessages: Bool {
        state.isLoadingThreadMessages(sessionID: sessionID)
    }

    private var shouldShowThreadLoading: Bool {
        !MobileDraftSessionID.isDraft(sessionID)
            && isThreadLoadingOverlayVisible
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

    // MARK: - Initial loading

    private func runThreadLoadingGate() async {
        minimumThreadLoadElapsed = false
        threadLoadingHideTask?.cancel()
        isThreadLoadingOverlayVisible = true
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            minimumThreadLoadElapsed = true
        }
        scheduleThreadLoadingHideIfReady()
    }

    private func handleThreadLoadingChange(_ isLoading: Bool) {
        threadLoadingHideTask?.cancel()
        guard !MobileDraftSessionID.isDraft(sessionID) else {
            isThreadLoadingOverlayVisible = false
            return
        }
        guard !isLoading else {
            isThreadLoadingOverlayVisible = true
            return
        }
        scheduleThreadLoadingHideIfReady()
    }

    private func scheduleThreadLoadingHideIfReady() {
        threadLoadingHideTask?.cancel()
        guard !MobileDraftSessionID.isDraft(sessionID) else {
            isThreadLoadingOverlayVisible = false
            return
        }
        guard minimumThreadLoadElapsed, !isThreadLoadingMessages else {
            isThreadLoadingOverlayVisible = true
            return
        }
        isThreadLoadingOverlayVisible = true
        threadLoadingHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isThreadLoadingOverlayVisible = false
            }
        }
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

    /// Scroll restoration after prepending older messages needs to survive lazy
    /// layout and row grouping changes. Repeating the same non-animated scroll
    /// across a handful of frames keeps the original anchor visible without
    /// fighting later user gestures.
    private func settleScroll<ID: Hashable>(proxy: ScrollViewProxy, to id: ID, anchor: UnitPoint) {
        loadMoreRestoreTask?.cancel()
        loadMoreRestoreTask = Task { @MainActor in
            var transaction = Transaction()
            transaction.animation = nil
            for _ in 0 ..< 8 {
                guard !Task.isCancelled else { return }
                withTransaction(transaction) {
                    proxy.scrollTo(id, anchor: anchor)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func scrollToBottomAfterLayout(proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard didEstablishInitialScroll, autoScrollEnabled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// Jump straight to the latest message the first time the thread's content
    /// is available, so an opened thread starts at the bottom instead of the
    /// top. The deferred scroll covers the lazy stack not having measured its
    /// full height on the first layout pass.
    private func establishInitialScroll(proxy: ScrollViewProxy, reason: String) {
        guard !didEstablishInitialScroll else {
            isInitialMessageListHidden = false
            mobileChatLogger.debug(
                "[InitialScroll] skip already-established reason=\(reason, privacy: .public) session=\(sessionID, privacy: .public)"
            )
            return
        }
        guard !isEstablishingInitialScroll else {
            mobileChatLogger.debug(
                "[InitialScroll] skip already-scheduled reason=\(reason, privacy: .public) session=\(sessionID, privacy: .public)"
            )
            return
        }
        guard !messages.isEmpty else {
            mobileChatLogger.debug(
                "[InitialScroll] waiting-empty reason=\(reason, privacy: .public) session=\(sessionID, privacy: .public)"
            )
            return
        }
        isEstablishingInitialScroll = true
        isInitialMessageListHidden = true
        isPinningLatestTurnToTop = false
        mobileChatLogger.info(
            "[InitialScroll] scheduled reason=\(reason, privacy: .public) session=\(sessionID, privacy: .public) messages=\(messages.count, privacy: .public) delay=0.5 scrollHeight=\(Double(scrollViewHeight), privacy: .public) available=\(Double(availableHeight), privacy: .public) minTail=\(Double(minTailSpacer), privacy: .public)"
        )
        initialScrollTask?.cancel()
        initialScrollTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                isEstablishingInitialScroll = false
                return
            }
            guard !Task.isCancelled else {
                isEstablishingInitialScroll = false
                mobileChatLogger.debug(
                    "[InitialScroll] cancelled session=\(sessionID, privacy: .public)"
                )
                return
            }
            let target = initialScrollTarget()
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(target.id, anchor: target.anchor)
            }
            didEstablishInitialScroll = true
            isEstablishingInitialScroll = false
            withAnimation(.easeInOut(duration: 0.18)) {
                isInitialMessageListHidden = false
            }
            mobileChatLogger.info(
                "[InitialScroll] scrolled target=\(target.name, privacy: .public) session=\(sessionID, privacy: .public) messages=\(messages.count, privacy: .public) distance=\(Double(distanceFromBottom), privacy: .public) tailY=\(Double(tailSpacerMinY), privacy: .public) available=\(Double(availableHeight), privacy: .public) minTail=\(Double(minTailSpacer), privacy: .public) userY=\(Double(latestUserMinY), privacy: .public)"
            )
        }
    }

    private func initialScrollTarget() -> (id: String, anchor: UnitPoint, name: String) {
        guard availableHeight > 0, tailSpacerMinY > 0 else {
            return (Self.bottomAnchorID, .bottom, "bottom-unmeasured")
        }
        // For real scrollable content, land on the true bottom so the newest
        // message is fully reached. For short threads, avoid aligning the
        // composer-clearance spacer as the primary visible content.
        if tailSpacerMinY > availableHeight {
            return (Self.bottomAnchorID, .bottom, "bottom")
        }
        return (Self.endOfScreenAnchorID, .bottom, "end-of-screen")
    }

    // MARK: - Send / Stop

    private func handleSend(_ trimmed: String) {
        // The sent message round-trips through the desktop; when it comes back
        // it is pinned to the top. Suppress bottom-follow so the streaming
        // reply fills the space below the question instead of yanking past it.
        awaitingSentUserMessage = true
        activeTurnUserMessageID = nil
        pendingIndicatorSpacerReduction = 0
        isPinningLatestTurnToTop = false
        canReleasePinnedTurnByScroll = false
        autoScrollEnabled = false
        Task {
            await state.sendUserMessage(trimmed, sessionID: sessionID)
            composer = ""
        }
    }

    // MARK: - Pin to top

    /// The user message whose geometry drives the active turn spacer. During a
    /// send this stays attached to that turn even if the user manually scrolls.
    private var trackedUserMessageID: UUID? {
        activeTurnUserMessageID ?? messages.last(where: { $0.role == .user })?.id
    }

    /// Visible chat area above the floating composer. `composerMinY` rides up
    /// with the keyboard, so this shrinks automatically when the keyboard opens.
    private var availableHeight: CGFloat {
        guard composerMinY > 0, scrollViewMinY > 0 else { return scrollViewHeight }
        return max(0, composerMinY - scrollViewMinY)
    }

    /// Minimum tail spacer: keeps the last line of a long reply clear of the
    /// area covered by the composer (and keyboard).
    private var minTailSpacer: CGFloat {
        max(0, scrollViewHeight - availableHeight) + 16
    }

    /// Keeps the floating scroll button above the composer, including queued
    /// message/question/plan banners and the keyboard-driven composer lift.
    private var scrollToBottomButtonBottomPadding: CGFloat {
        guard composerMinY > 0, scrollViewMinY > 0 else { return 80 }
        let coveredHeight = max(0, scrollViewMinY + scrollViewHeight - composerMinY)
        return coveredHeight + 12
    }

    /// Extra spacer for the active turn. It starts large enough for the sent
    /// user message to sit at the top, then shrinks as the assistant response
    /// grows into that space. Manual scroll releases active top-following, but
    /// the spacer remains attached to the turn so the layout can recover.
    private var pinTailSpacerExtraHeight: CGFloat {
        guard activeTurnUserMessageID != nil else { return 0 }
        guard scrollViewHeight > 0 else { return 0 }
        let latestTurnHeight = max(0, tailSpacerMinY - latestUserMinY)
            + pendingIndicatorSpacerReduction
        return max(0, scrollViewHeight - latestTurnHeight - minTailSpacer)
    }

    /// Pin a freshly sent user message to the top of the viewport.
    private func pinSentMessageToTop(_ id: UUID, proxy: ScrollViewProxy) {
        pinToTopTask?.cancel()
        canReleasePinnedTurnByScroll = false
        pinToTopTask = Task { @MainActor in
            // Give SwiftUI one frame to realize the new row, then keep
            // asserting the pin while the tracked-row geometry, tail spacer,
            // streaming indicator, and keyboard layout settle.
            try? await Task.sleep(for: .milliseconds(16))
            for attempt in 0 ..< 12 {
                guard !Task.isCancelled else { return }
                if attempt == 0 {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                } else {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, isPinningLatestTurnToTop else { return }
            canReleasePinnedTurnByScroll = true
        }
    }

    private func handleComposerBoundaryChange(
        oldValue: CGFloat,
        newValue: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard didEstablishInitialScroll, abs(newValue - oldValue) > 0.5 else { return }
        if isPinningLatestTurnToTop, let id = activeTurnUserMessageID ?? trackedUserMessageID {
            pinSentMessageToTop(id, proxy: proxy)
        } else if autoScrollEnabled {
            scrollToBottomAfterLayout(proxy: proxy)
        }
    }

    private func repinActiveTurnIfNeeded(proxy: ScrollViewProxy) -> Bool {
        guard isPinningLatestTurnToTop, let id = activeTurnUserMessageID else {
            return false
        }
        pinSentMessageToTop(id, proxy: proxy)
        return true
    }

    private func releasePinnedTurnToBottom(proxy: ScrollViewProxy) {
        pinToTopTask?.cancel()
        canReleasePinnedTurnByScroll = false
        isPinningLatestTurnToTop = false
        autoScrollEnabled = true
        scrollToBottomAfterLayout(proxy: proxy)
    }

    /// `minY` of the latest user message — fed back from `ChatMessageListView`.
    private func updateLatestUserMinY(_ value: CGFloat) {
        guard abs(value - latestUserMinY) > 0.5 else { return }
        var t = Transaction()
        t.animation = nil
        withTransaction(t) { latestUserMinY = value }
    }

    /// `minY` of the tail spacer — its distance from the user message is the
    /// height of the latest turn.
    private func updateTailSpacerMinY(_ value: CGFloat) {
        guard abs(value - tailSpacerMinY) > 0.5 else { return }
        let oldValue = tailSpacerMinY
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            tailSpacerMinY = value
            if pendingIndicatorSpacerReduction > 0, value > oldValue {
                pendingIndicatorSpacerReduction = 0
            }
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
            mobileChatLogger.info(
                "[ScrollButton] tap session=\(sessionID, privacy: .public) messages=\(messages.count, privacy: .public) distance=\(Double(distanceFromBottom), privacy: .public) padding=\(Double(scrollToBottomButtonBottomPadding), privacy: .public)"
            )
            autoScrollEnabled = true
            isUserDragging = false
            scrollToBottomFromButton(proxy)
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
        .frame(width: 48, height: 48)
        .contentShape(Circle())
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to bottom")
    }

    private func scrollToBottomFromButton(_ proxy: ScrollViewProxy) {
        mobileChatLogger.debug("[ScrollButton] scroll immediate")
        pinToTopTask?.cancel()
        canReleasePinnedTurnByScroll = false
        isPinningLatestTurnToTop = false
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
        DispatchQueue.main.async {
            mobileChatLogger.debug("[ScrollButton] scroll deferred")
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
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
