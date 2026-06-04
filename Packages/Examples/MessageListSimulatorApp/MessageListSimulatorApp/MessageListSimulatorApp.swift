import MessageList
import SwiftUI

@main
struct MessageListSimulatorApp: App {
    var body: some Scene {
        WindowGroup {
            MessageListManualTestView()
        }
    }
}

private struct MessageListManualTestView: View {
    @State private var messages: [DemoMessage] = DemoMessage.seedMessages
    @State private var isStreaming = false
    @State private var shouldScrollToBottom = false
    @State private var isAtBottom = false
    @State private var responseNumber = 0
    @State private var scrollRequestTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            MessageList(
                messages: messages,
                isStreaming: isStreaming,
                shouldScrollToBottom: shouldScrollToBottom,
                isAtBottom: $isAtBottom
            ) { message in
                DemoMessageRow(message: message)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            #if os(iOS)
            .background(Color(uiColor: .systemBackground))
            #else
            .background(Color(nsColor: .windowBackgroundColor))
            #endif
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("User") {
                    appendUserMessage()
                }
                .buttonStyle(.borderedProminent)

                Button("Response") {
                    appendAssistantMessage()
                }
                .buttonStyle(.bordered)

                Button(isStreaming ? "Stop" : "Stream") {
                    isStreaming ? stopStreaming() : startStreaming()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Bottom") {
                    requestScrollToBottom()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                Text("At bottom: \(isAtBottom ? "Yes" : "No")")
                Text("Messages: \(messages.count)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        #if os(iOS)
        .background(Color(uiColor: .secondarySystemBackground))
        #else
        .background(Color(nsColor: .controlBackgroundColor))
        #endif
    }

    private func appendUserMessage() {
        messages.append(DemoMessage(text: "User message \(messages.count + 1)", isUserMessage: true))
        requestScrollToBottom()
    }

    private func appendAssistantMessage() {
        responseNumber += 1
        let wasAtBottom = isAtBottom
        messages.append(DemoMessage(text: "\(responseNumber)", isUserMessage: false))
        if wasAtBottom {
            requestScrollToBottom()
        }
    }

    private func startStreaming() {
        streamTask?.cancel()
        appendUserMessage()
        isStreaming = true

        streamTask = Task { @MainActor in
            for index in 1...10 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, isStreaming else { return }
                let wasAtBottom = isAtBottom
                messages.append(DemoMessage(text: "stream \(index)", isUserMessage: false))
                if wasAtBottom {
                    requestScrollToBottom()
                }
            }
            isStreaming = false
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func requestScrollToBottom() {
        scrollRequestTask?.cancel()
        shouldScrollToBottom = false
        scrollRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            shouldScrollToBottom = true
        }
    }
}

private struct DemoMessageRow: View {
    let message: DemoMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.isUserMessage {
                Spacer(minLength: 48)
            }

            Text(message.text)
                .font(.body)
                .foregroundStyle(message.isUserMessage ? .white : .primary)
                .frame(minHeight: 44, alignment: .center)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        #if os(iOS)
                        .fill(message.isUserMessage ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                        #else
                        .fill(message.isUserMessage ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        #endif
                }
                .accessibilityIdentifier("message-\(message.text)")

            if !message.isUserMessage {
                Spacer(minLength: 48)
            }
        }
    }
}

private struct DemoMessage: MessageListItem {
    let id = UUID()
    var text: String
    var isUserMessage: Bool

    static let seedMessages: [DemoMessage] = (1...36).map {
        DemoMessage(text: "Seed \($0)", isUserMessage: $0.isMultiple(of: 5))
    }
}
