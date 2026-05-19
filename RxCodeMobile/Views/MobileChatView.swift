import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync

/// Read-write chat view. User messages are forwarded to the desktop and the
/// desktop agent's stream is mirrored back as `session_update` payloads.
struct MobileChatView: View {
    @EnvironmentObject private var state: MobileAppState
    let sessionID: String
    @State private var composer: String = ""
    @State private var isNearBottom: Bool = true
    @State private var showingQueueSheet = false
    @State private var didEstablishInitialScroll = false

    private static let bottomAnchorID = "message-list-bottom"
    private static let bottomContentPadding: CGFloat = 200
    private static let nearBottomThreshold: CGFloat = bottomContentPadding + 40

    var body: some View {
        activeThreadLayout
            .animation(.easeInOut(duration: 0.2), value: queuedMessages.count)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(title)
            .sheet(isPresented: $showingQueueSheet) {
                QueuedMessagesSheet(
                    messages: queuedMessages,
                    onRemove: removeQueued
                )
            }
    }

    // MARK: - Active Thread Layout

    private var activeThreadLayout: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ChatMessageListView(messages: messages)
                        Color.clear
                            .frame(height: Self.bottomContentPadding)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
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
