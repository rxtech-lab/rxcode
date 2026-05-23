#if DEBUG
import SwiftUI

nonisolated struct MessageListPreviewMessage: MessageListItem {
    let id: UUID
    var text: String
    var isUserMessage: Bool

    init(id: UUID = UUID(), text: String, isUserMessage: Bool) {
        self.id = id
        self.text = text
        self.isUserMessage = isUserMessage
    }
}

struct MessageListPreviewHarness: View {
    private let enablesPagination: Bool

    @State private var messages = MessageListPreviewMessage.initialMessages
    @State private var isStreaming = false
    @State private var shouldScrollToBottom = false
    @State private var isAtBottom = true
    @State private var previousPage = 0
    @State private var nextPage = 0
    @State private var scrollRequestTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?

    init(enablesPagination: Bool = false) {
        self.enablesPagination = enablesPagination
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()
            MessageList(
                messages: messages,
                isStreaming: isStreaming,
                shouldScrollToBottom: shouldScrollToBottom,
                isAtBottom: $isAtBottom,
                hasMorePrevious: { enablesPagination && previousPage < 2 },
                hasMore: { enablesPagination && nextPage < 2 },
                loadMorePrevious: loadMorePrevious,
                loadMore: loadMoreNext
            ) { message in
                MessageListPreviewRow(message: message)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            .background(previewBackgroundColor)
        }
        .frame(minWidth: 420, minHeight: 640)
        .onDisappear {
            scrollRequestTask?.cancel()
            streamTask?.cancel()
        }
    }

    private var previewBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("User") {
                appendUserMessage()
            }
            Button("Response") {
                appendMockResponse()
            }
            Button(isStreaming ? "Stop" : "Stream") {
                isStreaming ? stopStreaming() : startMockStream()
            }
            Spacer()
            Button("Bottom") {
                requestScrollToBottom()
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
    }

    private func appendUserMessage() {
        messages.append(.init(text: "Can you summarize the recent changes?", isUserMessage: true))
        requestScrollToBottom()
    }

    private func appendMockResponse() {
        let wasAtBottom = isAtBottom
        messages.append(.mockAssistantResponse(number: messages.count))
        if wasAtBottom {
            requestScrollToBottom()
        }
    }

    private func startMockStream() {
        streamTask?.cancel()
        messages.append(.init(text: "Please draft a short implementation plan.", isUserMessage: true))
        isStreaming = true
        requestScrollToBottom()

        streamTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard isStreaming else { return }
            messages.append(.mockStreamingResponse)
            isStreaming = false
            requestScrollToBottom()
        }
    }

    private func stopStreaming() {
        isStreaming = false
    }

    private func requestScrollToBottom() {
        scrollRequestTask?.cancel()
        shouldScrollToBottom = false
        scrollRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            shouldScrollToBottom = true
        }
    }

    private func loadMorePrevious() async throws {
        try await Task.sleep(for: .milliseconds(350))
        let page = previousPage + 1
        previousPage = page
        messages.insert(contentsOf: MessageListPreviewMessage.previousPage(page), at: 0)
    }

    private func loadMoreNext() async throws {
        try await Task.sleep(for: .milliseconds(350))
        let page = nextPage + 1
        nextPage = page
        messages.append(contentsOf: MessageListPreviewMessage.nextPage(page))
    }
}

struct MessageListPreviewRow: View {
    let message: MessageListPreviewMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.isUserMessage {
                Spacer(minLength: 48)
            }

            Text(message.text)
                .font(.body)
                .foregroundStyle(message.isUserMessage ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(message.isUserMessage ? Color.accentColor : Color.secondary.opacity(0.14))
                }

            if !message.isUserMessage {
                Spacer(minLength: 48)
            }
        }
    }
}

extension MessageListPreviewMessage {
    static let initialMessages: [MessageListPreviewMessage] = [
        .init(text: "Create a reusable message list package.", isUserMessage: true),
        .init(text: "I added a generic SwiftUI list that accepts caller-provided row rendering, handles bottom anchoring, supports pagination, and pins the latest user turn while the response grows.", isUserMessage: false),
        .init(text: "Can we test it with mock paging and responses?", isUserMessage: true),
        .init(text: "Yes. This preview includes top and bottom pagination plus buttons that append user messages and mock assistant responses.", isUserMessage: false),
    ]

    static let mockStreamingResponse = MessageListPreviewMessage(
        text: "Streaming finished with a mock response. The latest user message should remain pinned near the top until you scroll down.",
        isUserMessage: false
    )

    static func mockAssistantResponse(number: Int) -> MessageListPreviewMessage {
        MessageListPreviewMessage(
            text: "Mock response \(number): here is a longer assistant message so you can see content growth, wrapping, bottom anchoring, and lazy row rendering in the preview canvas.",
            isUserMessage: false
        )
    }

    static func previousPage(_ page: Int) -> [MessageListPreviewMessage] {
        [
            .init(text: "Older user prompt page \(page).", isUserMessage: true),
            .init(text: "Older assistant response page \(page). Scroll near the top again to load another previous page.", isUserMessage: false),
        ]
    }

    static func nextPage(_ page: Int) -> [MessageListPreviewMessage] {
        [
            .init(text: "Newer user prompt page \(page).", isUserMessage: true),
            .init(text: "Newer assistant response page \(page). Scroll near the bottom again to load another page.", isUserMessage: false),
        ]
    }
}

#Preview("MessageList") {
    MessageListPreviewHarness()
}
#endif
