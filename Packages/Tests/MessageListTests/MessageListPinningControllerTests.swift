import Foundation
import Testing
@testable import MessageList

@Suite("MessageList pinning controller")
struct MessageListPinningControllerTests {
    @Test("User message followed by ten non-streaming responses scrolls to bottom")
    func userMessageFollowedByTenResponsesScrollsBottom() {
        var controller = MessageListPinningController<UUID>()
        let userID = UUID()

        let pinAction = controller.handleLastMessageChange(
            id: userID,
            isUserMessage: true,
            isStreaming: false,
            isAtBottom: false
        )
        #expect(pinAction == .pinUserMessageToTop(userID))
        #expect(controller.isPinningUserMessage)

        for index in 0..<10 {
            let responseAction = controller.handleLastMessageChange(
                id: UUID(),
                isUserMessage: false,
                isStreaming: false,
                isAtBottom: true
            )
            #expect(
                responseAction == (index == 0 ? .releasePinAndScrollToBottom : .scrollToBottom),
                "response \(index + 1) should keep the transcript moving to the bottom"
            )
        }

        #expect(!controller.isPinningUserMessage)
    }

    @Test("Streaming responses keep the user message pinned until streaming ends")
    func streamingResponsesKeepPinUntilStreamEnds() {
        var controller = MessageListPinningController<UUID>()
        let userID = UUID()

        _ = controller.handleLastMessageChange(
            id: userID,
            isUserMessage: true,
            isStreaming: false,
            isAtBottom: true
        )

        for _ in 0..<10 {
            let action = controller.handleLastMessageChange(
                id: UUID(),
                isUserMessage: false,
                isStreaming: true,
                isAtBottom: true
            )
            #expect(action == .repinUserMessageToTop(userID))
            #expect(controller.isPinningUserMessage)
        }

        let endAction = controller.handleStreamingChange(oldValue: true, newValue: false, isAtBottom: true)
        #expect(endAction == .releasePinAndScrollToBottom)
        #expect(!controller.isPinningUserMessage)
    }

    @Test("Assistant message while scrolled up does not scroll to bottom")
    func assistantMessageWhileScrolledUpDoesNotScrollBottom() {
        var controller = MessageListPinningController<UUID>()

        let action = controller.handleLastMessageChange(
            id: UUID(),
            isUserMessage: false,
            isStreaming: false,
            isAtBottom: false
        )

        #expect(action == .none)
    }

    @Test("Assistant message while at bottom scrolls to bottom")
    func assistantMessageWhileAtBottomScrollsBottom() {
        var controller = MessageListPinningController<UUID>()

        let action = controller.handleLastMessageChange(
            id: UUID(),
            isUserMessage: false,
            isStreaming: false,
            isAtBottom: true
        )

        #expect(action == .scrollToBottom)
    }

    @Test("User message pins even when scrolled up")
    func userMessagePinsEvenWhenScrolledUp() {
        var controller = MessageListPinningController<UUID>()
        let userID = UUID()

        let action = controller.handleLastMessageChange(
            id: userID,
            isUserMessage: true,
            isStreaming: false,
            isAtBottom: false
        )

        #expect(action == .pinUserMessageToTop(userID))
        #expect(controller.isPinningUserMessage)
    }
}
