#if os(macOS)
import SwiftUI
import Testing
import ViewInspector
@testable import MessageList

@MainActor
@Suite("MessageList pinned turn SwiftUI behavior")
struct MessageListPinnedTurnSwiftUITests {
    @Test("Pinned user message releases when streaming content fills the reserved space")
    func pinnedUserMessageReleasesWhenStreamingContentFillsReservedSpace() async throws {
        let model = MessageListPinnedTurnModel()
        let view = MessageListPinnedTurnHarness(model: model)

        ViewHosting.host(
            view: view,
            size: CGSize(width: 260, height: 180),
            function: #function
        )
        defer { ViewHosting.expel(function: #function) }

        model.messages = [
            .init(text: "user", isUserMessage: true, height: 44),
        ]

        try await Task.sleep(for: .milliseconds(450))
        model.shouldObserveRelease = true
        model.messages.append(contentsOf: [
            .init(text: "assistant 1", isUserMessage: false, height: 88),
            .init(text: "assistant 2", isUserMessage: false, height: 88),
            .init(text: "assistant 3", isUserMessage: false, height: 88),
        ])

        try await waitUntil(timeout: .seconds(2)) {
            model.observedBottomRelease
        }

        #expect(model.isAtBottom)
    }
}

@MainActor
private final class MessageListPinnedTurnModel: ObservableObject {
    @Published var messages: [MessageListPinnedTurnMessage] = []
    @Published var isAtBottom = false
    var shouldObserveRelease = false
    var observedBottomRelease = false

    func updateIsAtBottom(_ value: Bool) {
        isAtBottom = value
        if shouldObserveRelease, value {
            observedBottomRelease = true
        }
    }
}

private struct MessageListPinnedTurnHarness: View {
    @ObservedObject var model: MessageListPinnedTurnModel

    var body: some View {
        MessageList(
            messages: model.messages,
            isStreaming: true,
            isAtBottom: Binding(
                get: { model.isAtBottom },
                set: { model.updateIsAtBottom($0) }
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

private func waitUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: @MainActor @escaping () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
        if ContinuousClock.now - start >= timeout {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: interval)
    }
}
#endif
