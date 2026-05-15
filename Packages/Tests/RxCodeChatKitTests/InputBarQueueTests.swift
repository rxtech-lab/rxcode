import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("InputBar queue interactions")
struct InputBarQueueTests {

    @Test("Draft typed while queued message auto-flushes is preserved")
    func draftTypedWhileQueuedMessageAutoFlushesIsPreserved() async throws {
        let window = WindowState()
        let bridge = ChatBridge()
        bridge.isStreaming = true

        var sentPrompts: [String] = []
        bridge.enqueueMessageHandler = { text, attachments in
            window.enqueueMessage(text: text, attachments: attachments)
        }
        bridge.dequeueNextForFlushHandler = {
            window.dequeueNext()
        }
        bridge.sendHandler = {
            sentPrompts.append(window.inputText)
            window.inputText = ""
            window.attachments = []
            bridge.isStreaming = true
        }

        let sut = InputBarView(
            windowState: window,
            chatBridge: bridge,
            accessory: EmptyView()
        ) {
            EmptyView()
        }

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }

        try type("queued turn", in: sut)
        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: "chat-send-button")
            .button()
            .tap()

        #expect(window.messageQueue.map(\.text) == ["queued turn"])
        #expect(window.inputText.isEmpty)

        try type("draft typed during queued processing", in: sut)
        bridge.isStreaming = false
        try await Task.sleep(for: .milliseconds(100))

        #expect(sentPrompts == ["queued turn"])
        #expect(window.messageQueue.isEmpty)
        #expect(window.inputText == "draft typed during queued processing")
        try await Task.sleep(for: .milliseconds(350))
    }

    private func type<V: View>(_ text: String, in view: V) throws {
        let input = try view.inspect()
            .find(IMETextView.self)
            .actualView()
        input.text = text
    }

}
