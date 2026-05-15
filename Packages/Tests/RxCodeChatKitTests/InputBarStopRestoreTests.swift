import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("InputBar stop button")
struct InputBarStopRestoreTests {

    @Test("Stop button restores both text and attachments via cancel handler")
    func stopButtonRestoresTextAndAttachments() async throws {
        let window = WindowState()
        let bridge = ChatBridge()

        // The chat has already sent a message with an image attachment and is now streaming.
        // The composer has been cleared, mirroring what `AppState.send` does right after
        // it dispatches the prompt to the CLI.
        bridge.isStreaming = true
        window.inputText = ""
        window.attachments = []

        let pendingUserText = "describe this image"
        let imageAttachment = Attachment(
            type: .image,
            name: "rxcode-img-02AF8CDE.png",
            path: "/tmp/rxcode-img-02AF8CDE.png",
            fileSize: 1024
        )

        // Stand-in for `AppState.cancelStreaming` after the fix — restore the in-flight
        // user message into the composer, text AND attachments together.
        bridge.cancelStreamingHandler = {
            bridge.isStreaming = false
            window.inputText = pendingUserText
            window.attachments = [imageAttachment]
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

        // Drive the real UI: locate the stop button via its accessibility id and tap it.
        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: "chat-stop-button")
            .button()
            .tap()

        // `stopGeneration` dispatches via a Task; let it run.
        try await Task.sleep(for: .milliseconds(50))

        #expect(window.inputText == pendingUserText)
        #expect(window.attachments.count == 1)
        #expect(window.attachments.first?.name == "rxcode-img-02AF8CDE.png")
        #expect(window.attachments.first?.type == .image)

        // The attachment preview row should now be back on screen, rendering the
        // attachment's name through `AttachmentPreviewItem`.
        #expect((try? sut.inspect().find(text: "rxcode-img-02AF8CDE.png")) != nil)
    }

    @Test("Cancel handler that only restores text loses image attachments (regression guard)")
    func cancelHandlerThatOnlyRestoresTextLosesAttachments() async throws {
        // This test pins the bug we just fixed: if a future change reverts to only
        // restoring `inputText` on cancel, the attachments silently disappear.
        // It documents that behavior so anyone editing the cancel path has to
        // think about attachments too.
        let window = WindowState()
        let bridge = ChatBridge()
        bridge.isStreaming = true

        bridge.cancelStreamingHandler = {
            bridge.isStreaming = false
            window.inputText = "buggy restore"
            // Intentionally NOT restoring `window.attachments`.
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

        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: "chat-stop-button")
            .button()
            .tap()
        try await Task.sleep(for: .milliseconds(50))

        #expect(window.inputText == "buggy restore")
        #expect(window.attachments.isEmpty)
    }
}
