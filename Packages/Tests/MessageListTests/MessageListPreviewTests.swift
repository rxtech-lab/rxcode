#if DEBUG
import SwiftUI
import Testing
import ViewInspector
@testable import MessageList

@MainActor
@Suite("MessageList preview")
struct MessageListPreviewTests {
    @Test("Sending a user message followed by assistant messages renders the last assistant response")
    func sendingUserMessageFollowedByAssistantMessagesRendersLastAssistantResponse() throws {
        let model = MessageListSendModel()
        let view = MessageListSendHarness(model: model)

        try view.inspect().find(button: "Send user").tap()
        try view.inspect().find(button: "Send 1").tap()
        try view.inspect().find(button: "Send 2").tap()
        try view.inspect().find(button: "Send 3").tap()
        try view.inspect().find(button: "Send 4").tap()

        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(texts.contains("4"))
    }

    @Test("Incoming assistant messages while scrolled up keep the bottom binding false")
    func incomingAssistantMessagesWhileScrolledUpKeepBottomBindingFalse() throws {
        let model = MessageListSendModel()
        let view = MessageListSendHarness(model: model)

        try view.inspect().find(button: "Scroll up").tap()
        try view.inspect().find(button: "Send 1").tap()
        try view.inspect().find(button: "Send 2").tap()
        try view.inspect().find(button: "Send 3").tap()
        try view.inspect().find(button: "Send 4").tap()

        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(texts.contains("4"))
        #expect(!model.isAtBottom)
        #expect(!model.shouldScrollToBottom)
    }
}

private final class MessageListSendModel: ObservableObject {
    @Published var messages: [MessageListPreviewMessage] = []
    @Published var isAtBottom = true
    @Published var shouldScrollToBottom = false

    func sendUserMessage() {
        messages.append(.init(text: "user", isUserMessage: true))
        requestScrollToBottom()
    }

    func sendAssistantMessage(_ text: String) {
        let wasAtBottom = isAtBottom
        messages.append(.init(text: text, isUserMessage: false))
        if wasAtBottom {
            requestScrollToBottom()
        }
    }

    func setScrolledUp() {
        isAtBottom = false
        shouldScrollToBottom = false
    }

    private func requestScrollToBottom() {
        shouldScrollToBottom = true
    }
}

private struct MessageListSendHarness: View {
    @ObservedObject var model: MessageListSendModel

    var body: some View {
        VStack {
            Button("Send user") {
                model.sendUserMessage()
            }

            Button("Scroll up") {
                model.setScrolledUp()
            }

            ForEach(["1", "2", "3", "4"], id: \.self) { text in
                Button("Send \(text)") {
                    model.sendAssistantMessage(text)
                }
            }

            MessageList(
                messages: model.messages,
                shouldScrollToBottom: model.shouldScrollToBottom,
                isAtBottom: Binding(
                    get: { model.isAtBottom },
                    set: { model.isAtBottom = $0 }
                )
            ) { message in
                MessageListPreviewRow(message: message)
            }
        }
    }
}
#endif
