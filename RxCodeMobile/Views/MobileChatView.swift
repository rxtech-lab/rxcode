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
    @EnvironmentObject var state: MobileAppState
    let sessionID: String
    /// Invoked after the thread is archived or deleted so the parent can pop
    /// this view — the thread is no longer reachable from the active list.
    var onClose: () -> Void = {}
    @State var composer: String = ""
    @State var isNearBottom: Bool = true
    @State var showingQueueSheet = false
    /// Set once the thread has been scrolled to its newest message on open.
    /// Until then, an arriving message jumps to the bottom without animation;
    /// after, message updates animate as the streaming follow.
    @State var didEstablishInitialScroll = false
    @State var showingRenameSheet = false
    @State var showingArchiveConfirm = false
    @State var showingDeleteConfirm = false
    @State var showingTodoSheet = false
    @State var showingRunProfiles = false
    @State var showingBrowser = false
    @State var showingChanges = false
    /// The question request whose sheet is currently presented, if any.
    @State var presentedQuestion: PendingQuestionPayload?
    /// The plan whose review sheet is currently presented, if any.
    @State var presentedPlan: PendingPlan?
    /// Local file link tapped in rendered markdown. Mobile fetches the content
    /// from the paired desktop before presenting it.
    @State var presentedFileLink: LocalFileLink?
    /// The message that sat at the top before an older page was requested. The
    /// viewport is restored to it after the page is prepended so the content
    /// the user was reading doesn't jump.
    @State var pendingTopAnchorID: UUID?
    /// Re-asserts the preserved position after SwiftUI has laid out a prepended
    /// page. A single `scrollTo` can fire before the lazy stack has realized the
    /// old anchor row.
    @State var loadMoreRestoreTask: Task<Void, Never>?
    /// Re-asserts the just-sent message pin while lazy row geometry, dynamic
    /// spacer height, and keyboard-driven composer movement settle.
    @State var pinToTopTask: Task<Void, Never>?
    /// Re-asserts the first scroll-to-bottom while the lazy stack and composer
    /// geometry settle on thread entry.
    @State var initialScrollTask: Task<Void, Never>?
    /// Owns coalesced automatic bottom-follow while streamed content grows.
    @State var autoBottomScrollTask: Task<Void, Never>?
    /// Prevents repeated scheduling while the delayed initial scroll is
    /// waiting for the first loaded page to finish laying out.
    @State var isEstablishingInitialScroll = false
    /// Hides the thread while the initial delayed scroll is pending, avoiding
    /// a visible flash at the top before the view lands on the latest message.
    @State var isInitialMessageListHidden = true
    /// Gates the scroll-up "load more" trigger until the initial scroll-to-
    /// bottom has settled, so opening a thread doesn't immediately page back.
    @State var didSettleInitialScroll = false
    /// True while the user is actively driving the scroll view (dragging or
    /// momentum). Layout- and keyboard-induced offset shifts happen outside
    /// these phases and must not be mistaken for a deliberate scroll-up.
    @State var isUserDragging = false
    /// While `false`, the stream no longer pulls the viewport to the bottom —
    /// set when the user scrolls up so they can read history without being
    /// yanked back down. Re-armed once they return to the bottom.
    @State var autoScrollEnabled = true
    /// Full height of the scroll view (independent of the keyboard).
    @State var scrollViewHeight: CGFloat = 0
    /// Global `minY` of the scroll view.
    @State var scrollViewMinY: CGFloat = 0
    /// Global `minY` of the floating composer stack — its top is the boundary
    /// between the visible chat area and the area covered by composer + keyboard.
    @State var composerMinY: CGFloat = 0
    /// `minY` of the latest user message in `chatContentCoordinateSpace`.
    @State var latestUserMinY: CGFloat = 0
    /// `minY` of the tail spacer in `chatContentCoordinateSpace`.
    @State var tailSpacerMinY: CGFloat = 0
    /// Set by `handleSend`; the next appended user message is the one we sent
    /// and should be pinned to the top of the viewport.
    @State var awaitingSentUserMessage = false
    /// User message for the active turn. Its trailing spacer persists even
    /// after manual scroll and shrinks as the assistant response fills in.
    @State var activeTurnUserMessageID: UUID?
    /// Immediate spacer reduction used while SwiftUI has not yet reported the
    /// streaming indicator's new tail geometry.
    @State var pendingIndicatorSpacerReduction: CGFloat = 0
    /// True only for the active send flow where the just-sent user message is
    /// actively kept at the top while layout and keyboard geometry settle.
    @State var isPinningLatestTurnToTop = false
    /// Prevents stale/user scroll phase callbacks from immediately canceling a
    /// new programmatic top-pin before it has settled.
    @State var canReleasePinnedTurnByScroll = false
    @State var distanceFromBottom: CGFloat = 0
    @State var lastAutoBottomScrollDate = Date.distantPast
    @State var packageShouldScrollToBottom = false
    @State var packageScrollRequestTask: Task<Void, Never>?
    @State var minimumThreadLoadElapsed = false
    @State var isThreadLoadingOverlayVisible = true
    @State var threadLoadingHideTask: Task<Void, Never>?

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
    /// Maximum automatic bottom-follow cadence while content streams in.
    private static let autoBottomScrollInterval: TimeInterval = 2
    private static let pinToTopAnimationDuration: Duration = .milliseconds(320)
    private static let pinToTopAnimationSeconds: Double = 0.32

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
                AnalyticsService.shared.log(.threadOpened, parameters: [
                    "session_id": sessionID,
                ])
                await runThreadLoadingGate()
            }
            .task(id: resolvedSessionID) {
                if !MobileDraftSessionID.isDraft(resolvedSessionID) {
                    await state.subscribe(to: resolvedSessionID)
                }
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
                    .mobileSheetPresentation()
                }
            }
            .sheet(isPresented: $showingChanges) {
                ThreadChangesSheet(sessionID: sessionID)
                    .environmentObject(state)
                    .mobileSheetPresentation([.large])
            }
            .sheet(item: $presentedFileLink) { link in
                MobileRemoteFilePreviewSheet(link: link)
                    .environmentObject(state)
                    .mobileSheetPresentation([.large])
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
                .mobileSheetPresentation([.large])
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

    // MARK: - Active Thread Layout

    private var activeThreadLayout: some View {
        ZStack(alignment: .bottom) {
            ChatTranscriptList(
                items: mobileTranscriptItems,
                isStreaming: isStreaming,
                shouldScrollToBottom: packageShouldScrollToBottom,
                isAtBottom: $isNearBottom,
                hasMorePrevious: {
                    didSettleInitialScroll
                        && state.hasMoreMessages(sessionID: sessionID)
                        && !state.isLoadingMoreMessages(sessionID: sessionID)
                },
                loadMorePrevious: loadMorePreviousMessages,
                rowPadding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16),
                accessibilityIdentifier: "chat-message-list"
            ) { accessory in
                mobileTranscriptAccessory(accessory)
            }
            .opacity(isInitialMessageListHidden && !messages.isEmpty ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: isStreaming)
            .animation(.easeInOut(duration: 0.2), value: isLoadingMore)
            .animation(.easeInOut(duration: 0.18), value: isInitialMessageListHidden)
            .mobileDismissesKeyboardOnScroll(.interactively)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { rect in
                scrollViewHeight = rect.height
                scrollViewMinY = rect.minY
            }
            .onAppear {
                establishInitialPackageScroll(reason: "onAppear")
            }
            .task {
                try? await Task.sleep(for: .seconds(0.8))
                didSettleInitialScroll = true
            }
            .onChange(of: isNearBottom) { _, nearBottom in
                if nearBottom {
                    autoScrollEnabled = true
                    isPinningLatestTurnToTop = false
                } else if didEstablishInitialScroll {
                    autoScrollEnabled = false
                }
            }
            .onChange(of: messages.last?.id) { _, _ in
                guard let last = messages.last else { return }
                if last.role == .user, awaitingSentUserMessage {
                    awaitingSentUserMessage = false
                    autoScrollEnabled = false
                    activeTurnUserMessageID = last.id
                    isPinningLatestTurnToTop = true
                    didEstablishInitialScroll = true
                    isInitialMessageListHidden = false
                    return
                }
                if !didEstablishInitialScroll {
                    establishInitialPackageScroll(reason: "messagesArrived")
                } else if autoScrollEnabled {
                    requestPackageScrollToBottom(reason: "lastMessage")
                }
            }
            .onChange(of: messages.last?.content) { _, _ in
                guard didEstablishInitialScroll, autoScrollEnabled else { return }
                requestPackageScrollToBottom(reason: "messageContent")
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    pendingIndicatorSpacerReduction = 0
                    isPinningLatestTurnToTop = false
                }
                guard didEstablishInitialScroll, autoScrollEnabled else { return }
                requestPackageScrollToBottom(reason: streaming ? "streamingStarted" : "streamingEnded")
            }
            .onChange(of: composerMinY) { oldValue, newValue in
                guard didEstablishInitialScroll, abs(newValue - oldValue) > 0.5, autoScrollEnabled else { return }
                requestPackageScrollToBottom(reason: "composer")
            }
            .overlay(alignment: .bottomLeading) {
                if !isNearBottom {
                    scrollToBottomButton()
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
        .accessibilityIdentifier("chat-screen")
        .environment(\.openURL, OpenURLAction { url in
            if let link = LocalFileLink.parse(url) {
                presentedFileLink = link
                return .handled
            }
            return .systemAction
        })
    }

    private var mobileTranscriptItems: [ChatTranscriptListItem] {
        var items: [ChatTranscriptListItem] = [
            .accessory(.init(id: "mobile-top-padding", kind: .topPadding)),
        ]
        if isLoadingMore {
            items.append(.accessory(.init(id: "mobile-loading-previous", kind: .loadingPrevious)))
        }
        items += ChatTranscriptListItem.items(for: messages)
        if shouldShowEndLoadingIndicator {
            items.append(.accessory(.init(id: "mobile-end-loading-indicator", kind: .loadingNext)))
        }
        items.append(.accessory(.init(id: "mobile-bottom-spacer", kind: .custom)))
        return items
    }

    private var shouldShowEndLoadingIndicator: Bool {
        isStreaming || (isThreadLoadingMessages && messages.isEmpty)
    }

    @ViewBuilder
    private func mobileTranscriptAccessory(_ accessory: ChatTranscriptAccessory) -> some View {
        switch accessory.kind {
        case .topPadding:
            Color.clear.frame(height: 8)
        case .loadingPrevious:
            loadMoreSpinner
        case .loadingNext, .streamingIndicator:
            MobileStreamingIndicator(isThinking: isThinking)
                .transition(.opacity)
        case .webPreview:
            EmptyView()
        case .custom:
            if accessory.id == "mobile-bottom-spacer" {
                Color.clear.frame(height: minTailSpacer)
            } else {
                EmptyView()
            }
        }
    }

    private var messages: [ChatMessage] {
        state.messages(sessionID: sessionID)
    }

    var currentProjectID: UUID? {
        state.sessionSummary(sessionID: sessionID)?.projectId
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

    var title: String {
        state.sessionSummary(sessionID: sessionID)?.title ?? "Thread"
    }

    /// Live todos from synced messages when available, otherwise from the
    /// desktop session summary. Codex plan updates arrive as desktop-owned
    /// snapshots rather than `TodoWrite` message tool calls.
    var todos: [TodoItem]? {
        TodoExtractor.latest(in: messages)
            ?? state.sessionSummary(sessionID: sessionID)?.todos
    }

    /// The desktop-generated summary for this thread, if one exists. Summaries
    /// are produced once a thread finishes a turn, so live threads may not have
    /// one yet.
    private var threadSummary: MobileThreadSummary? {
        state.threadSummary(sessionID: sessionID)
    }

    private var resolvedSessionID: String {
        state.resolveSessionID(sessionID)
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
            && messages.isEmpty
            && isThreadLoadingOverlayVisible
    }

    var queuedMessages: [QueuedUserMessage] {
        state.queuedMessages(sessionID: sessionID)
    }

    /// `AskUserQuestion` calls awaiting an answer for this thread.
    var sessionQuestions: [PendingQuestionPayload] {
        state.pendingQuestions(sessionID: sessionID)
    }

    /// Every plan card for this thread (pending + decided), derived from the
    /// synced messages via the shared `PlanLogic`.
    var sessionPlans: [PendingPlan] {
        state.pendingPlans(sessionID: sessionID)
    }

    /// Plans still awaiting a decision — what the plan banner surfaces.
    var pendingPlans: [PendingPlan] {
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

    private func loadMorePreviousMessages() async throws {
        _ = await state.loadMoreMessages(sessionID: sessionID)
    }

    private func establishInitialPackageScroll(reason: String) {
        guard !didEstablishInitialScroll else {
            isInitialMessageListHidden = false
            return
        }
        guard !messages.isEmpty else { return }
        didEstablishInitialScroll = true
        isInitialMessageListHidden = true
        requestPackageScrollToBottom(reason: reason)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeInOut(duration: 0.18)) {
                isInitialMessageListHidden = false
            }
        }
    }

    private func requestPackageScrollToBottom(reason: String) {
        packageScrollRequestTask?.cancel()
        packageShouldScrollToBottom = false
        mobileChatLogger.debug(
            "[MessageList] scrollToBottom requested reason=\(reason, privacy: .public) session=\(sessionID, privacy: .public)"
        )
        packageScrollRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            packageShouldScrollToBottom = true
        }
    }

    // MARK: - Send / Stop

    private func handleSend(_ trimmed: String) {
        // The sent message round-trips through the desktop; when it comes back
        // it is pinned to the top. Suppress bottom-follow so the streaming
        // reply fills the space below the question instead of yanking past it.
        autoBottomScrollTask?.cancel()
        autoBottomScrollTask = nil
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

    private func handleStop() {
        guard !sessionID.isEmpty else { return }
        Task { await state.cancelStream(sessionID: sessionID) }
    }

    private func removeQueued(_ queued: QueuedUserMessage) {
        Task { await state.removeQueuedMessage(sessionID: sessionID, queuedID: queued.id) }
    }

    // MARK: - Scroll to bottom button

    private func scrollToBottomButton() -> some View {
        Button {
            mobileChatLogger.info(
                "[ScrollButton] tap session=\(sessionID, privacy: .public) messages=\(messages.count, privacy: .public) distance=\(Double(distanceFromBottom), privacy: .public) padding=\(Double(scrollToBottomButtonBottomPadding), privacy: .public)"
            )
            autoScrollEnabled = true
            isUserDragging = false
            autoBottomScrollTask?.cancel()
            autoBottomScrollTask = nil
            isPinningLatestTurnToTop = false
            requestPackageScrollToBottom(reason: "button")
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

}
