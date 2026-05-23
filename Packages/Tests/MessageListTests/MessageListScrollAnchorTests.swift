import CoreGraphics
import Testing
@testable import MessageList

@Suite("MessageListScrollAnchor")
struct MessageListScrollAnchorTests {
    @Test("Content growth while anchored requests bottom scroll")
    func contentGrowthWhileAnchoredRequestsBottomScroll() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)

        let decision = anchor.apply(contentHeight: 1400, visibleMaxY: 1000)

        #expect(decision == .scrollToBottom)
        #expect(anchor.isNearBottom)
    }

    @Test("Content growth while scrolled up does not re-anchor")
    func contentGrowthWhileScrolledUpDoesNotReanchor() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 600)

        let decision = anchor.apply(contentHeight: 1400, visibleMaxY: 600)

        #expect(decision == .none)
        #expect(!anchor.isNearBottom)
    }

    @Test("Reset restores bottom anchoring")
    func resetRestoresBottomAnchoring() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 500)
        #expect(!anchor.isNearBottom)

        anchor.resetToBottom()

        #expect(anchor.isNearBottom)
    }
}
