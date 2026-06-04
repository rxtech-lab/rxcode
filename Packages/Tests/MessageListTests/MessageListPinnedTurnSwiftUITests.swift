#if os(macOS)
import SwiftUI
import Testing
import ViewInspector
@testable import MessageList

@MainActor
@Suite("MessageList pinned turn SwiftUI behavior")
struct MessageListPinnedTurnSwiftUITests {
    @Test("Streaming content that fills the reserved space keeps the list following the bottom")
    func streamingContentFillingReservedSpaceFollowsBottom() async throws {
        let model = MessageListPinnedTurnModel()
        let view = MessageListPinnedTurnHarness(model: model)

        ViewHosting.host(
            view: view,
            size: CGSize(width: 260, height: 180),
            function: #function
        )
        defer { ViewHosting.expel(function: #function) }

        // A fresh user message pins to the top with reserved space below it.
        model.messages = [
            .init(text: "user", isUserMessage: true, height: 44),
        ]

        try await Task.sleep(for: .milliseconds(450))

        // The streaming response grows the turn until it outgrows the viewport,
        // collapsing the reserved space. The pin releases and the list must keep
        // following the bottom — it must not be stranded above the bottom.
        model.messages.append(contentsOf: [
            .init(text: "assistant 1", isUserMessage: false, height: 88),
            .init(text: "assistant 2", isUserMessage: false, height: 88),
            .init(text: "assistant 3", isUserMessage: false, height: 88),
        ])

        // Let the layout settle after the turn fills the viewport, then assert the
        // list reports it is following the bottom rather than stranded.
        try await Task.sleep(for: .milliseconds(600))

        #expect(model.isAtBottom)
    }
}

@MainActor
private final class MessageListPinnedTurnModel: ObservableObject {
    @Published var messages: [MessageListPinnedTurnMessage] = []
    @Published var isAtBottom = false
}

private struct MessageListPinnedTurnHarness: View {
    @ObservedObject var model: MessageListPinnedTurnModel

    var body: some View {
        MessageList(
            messages: model.messages,
            isStreaming: true,
            isAtBottom: Binding(
                get: { model.isAtBottom },
                set: { model.isAtBottom = $0 }
            )
        ) { message in
            Text(message.text)
                .frame(maxWidth: .infinity, minHeight: message.height, alignment: .leading)
        }
    }
}

private struct MessageListPinnedTurnMessage: MessageListItem {
    let id = UUID()
    let text: String
    let isUserMessage: Bool
    let height: CGFloat
}
#endif
