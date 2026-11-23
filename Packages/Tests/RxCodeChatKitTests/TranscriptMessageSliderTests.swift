import RxCodeCore
import SwiftUI
import Testing
@testable import RxCodeChatKit

@MainActor
struct TranscriptMessageSliderTests {
    @Test func stopsMatchNativeRowsAfterGroupingDeduplicationAndPaging() throws {
        let first = ChatTranscriptListItem.message(ChatMessage(role: .user, content: "First"))
        let second = ChatTranscriptListItem.message(ChatMessage(role: .user, content: "Second"))
        let toolGroup = try #require(ChatTranscriptListItem.transientGroup([ChatMessage(role: .assistant, content: "Tool")]))
        let accessory = ChatTranscriptListItem.accessory(.init(id: "loading", kind: .loadingPrevious))
        let reply = ChatTranscriptListItem.message(ChatMessage(role: .assistant, content: "Reply"))
        let rows = [accessory, first, toolGroup, first, reply, second]
        let stops = TranscriptMessageStop.stops(in: rows)
        #expect(stops.map(\.id) == [first.id, second.id])
        #expect(stops.map(\.row) == [1, 4])

        let earlier = ChatTranscriptListItem.message(ChatMessage(role: .user, content: "Earlier"))
        #expect(TranscriptMessageStop.stops(in: [earlier] + rows).map(\.row) == [0, 2, 5])
        #expect(TranscriptMessageStop.stops(in: [accessory, reply]).isEmpty)
    }

    #if os(macOS)
    @Test func scrollRevealsSliderAndJumpSurvivesStreaming() async throws {
        _ = NSApplication.shared
        let model = SliderTestModel()
        let host = NSHostingView(rootView: SliderTestChat(model: model).environment(ChatBridge()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(350))

        let table = try #require(findTable(in: host))
        let scroll = try #require(table.enclosingScrollView)
        let middle = CGPoint(x: host.bounds.maxX - 10, y: host.bounds.midY)
        #expect(host.hitTest(middle) !== host)

        // Move just a few points from the pinned live turn. The slider must be
        // able to detach from that turn even while the list is still near bottom.
        let clip = scroll.contentView
        let top = max(0, clip.bounds.minY - 12)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: CGPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(100))
        try #require(host.hitTest(middle) === host)
        let stops = TranscriptMessageStop.stops(in: model.items)
        let target = stops[stops.count / 2].row
        func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        try send(.leftMouseDown, at: CGPoint(x: middle.x, y: middle.y - 64))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(host.hitTest(middle) === host)
        try send(.leftMouseDragged, at: middle)
        try send(.leftMouseUp, at: middle)
        try await Task.sleep(for: .milliseconds(180))
        #expect(abs(clip.bounds.minY - table.rect(ofRow: target).minY) < 2)
        #expect(!model.isAtBottom)

        model.items.append(.message(ChatMessage(role: .assistant, content: "More output")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(clip.bounds.minY - table.rect(ofRow: target).minY) < 2)
        model.isStreaming = false
        try await Task.sleep(for: .milliseconds(1200))
        #expect(abs(clip.bounds.minY - table.rect(ofRow: target).minY) < 2)
        #expect(host.hitTest(middle) !== host)

        model.items.append(.message(ChatMessage(role: .user, content: "A new turn")))
        model.isStreaming = true
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(clip.bounds.minY - table.rect(ofRow: model.items.count - 1).minY) < 40)
        #expect(model.isAtBottom)
    }

    private func findTable(in view: NSView) -> NSTableView? {
        (view as? NSTableView) ?? view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }
    #endif
}

#if os(macOS)
@MainActor @Observable
private final class SliderTestModel {
    var isAtBottom = true
    var isStreaming = true
    var items: [ChatTranscriptListItem] = (1...15).flatMap { turn in
        [.message(ChatMessage(role: .user, content: "Question \(turn)")),
         .message(ChatMessage(role: .assistant, content: "Reply \(turn)"))]
    }
}

private struct SliderTestChat: View {
    @Bindable var model: SliderTestModel

    var body: some View {
        ChatTranscriptList(items: model.items, isStreaming: model.isStreaming, isAtBottom: $model.isAtBottom) { _ in
            EmptyView()
        }
    }
}
#endif
