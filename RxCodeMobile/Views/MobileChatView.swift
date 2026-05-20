import SwiftUI
import Combine
import RxCodeCore
import RxCodeChatKit
import RxCodeSync

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

    private static let bottomAnchorID = "message-list-bottom"
    private static let bottomContentPadding: CGFloat = 200
    private static let nearBottomThreshold: CGFloat = bottomContentPadding + 40

    var body: some View {
        activeThreadLayout
            .animation(.easeInOut(duration: 0.2), value: queuedMessages.count)
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
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Thread actions")
            }
        }
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
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let distanceFromBottom = geo.contentSize.height - geo.visibleRect.maxY
                    return distanceFromBottom <= Self.nearBottomThreshold
                } action: { _, newValue in
                    if isNearBottom != newValue { isNearBottom = newValue }
                }
                .onAppear {
                    if !didEstablishInitialScroll {
                        didEstablishInitialScroll = true
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    guard didEstablishInitialScroll else {
                        didEstablishInitialScroll = true
                        return
                    }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: messages.last?.content) { _, _ in
                    guard didEstablishInitialScroll, isNearBottom else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: isStreaming) { _, streaming in
                    // Keep the newly appeared loading indicator in view.
                    guard streaming, didEstablishInitialScroll, isNearBottom else { return }
                    withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
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

    private var isStreaming: Bool {
        state.isSessionStreaming(sessionID)
    }

    private var isThinking: Bool {
        state.isSessionThinking(sessionID)
    }

    private var queuedMessages: [QueuedUserMessage] {
        state.queuedMessages(sessionID: sessionID)
    }

    // MARK: - Send / Stop

    private func handleSend(_ trimmed: String) {
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
