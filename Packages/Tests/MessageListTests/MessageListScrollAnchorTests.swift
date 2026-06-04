import CoreGraphics
import Testing
@testable import MessageList

@Suite("MessageListScrollAnchor")
struct MessageListScrollAnchorTests {
    @Test("Content growth while anchored requests bottom scroll")
    func contentGrowthWhileAnchoredRequestsBottomScroll() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)

        let decision = anchor.apply(contentHeight: 1400, visibleMaxY: 1000, isUserDriven: false)

        #expect(decision == .scrollToBottom)
        #expect(anchor.isNearBottom)
    }

    @Test("Content growth while scrolled up does not re-anchor")
    func contentGrowthWhileScrolledUpDoesNotReanchor() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)
        // User scrolls up — a user-driven stable frame un-sticks the anchor.
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 600, isUserDriven: true)

        let decision = anchor.apply(contentHeight: 1400, visibleMaxY: 600, isUserDriven: false)

        #expect(decision == .none)
        #expect(!anchor.isNearBottom)
    }

    @Test("Reset restores bottom anchoring")
    func resetRestoresBottomAnchoring() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 500, isUserDriven: true)
        #expect(!anchor.isNearBottom)

        anchor.resetToBottom()

        #expect(anchor.isNearBottom)
    }

    @Test("Tall card layout settle does not un-stick the anchor")
    func tallCardLayoutSettleKeepsAnchorSticky() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        // User is following the bottom.
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)

        // A tall Edit card lays out in one frame: content grows but the visible
        // rect hasn't been re-anchored yet, so distance is huge. Still sticky;
        // schedules a scroll-to-bottom.
        let growth = anchor.apply(contentHeight: 1800, visibleMaxY: 1000, isUserDriven: false)
        #expect(growth == .scrollToBottom)
        #expect(anchor.isNearBottom)

        // Before the (async/throttled) scroll executes, a *non*-user-driven
        // stable frame arrives while distance is still huge. This must NOT
        // un-stick the anchor — otherwise the pending auto-scroll bails and the
        // view is stranded above the bottom.
        let settle = anchor.apply(contentHeight: 1800, visibleMaxY: 1000, isUserDriven: false)
        #expect(settle == .none)
        #expect(anchor.isNearBottom)
    }

    @Test("User scroll up still releases the anchor after a tall card")
    func userScrollUpReleasesAnchorAfterTallCard() {
        var anchor = MessageListScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)
        _ = anchor.apply(contentHeight: 1800, visibleMaxY: 1000, isUserDriven: false)
        // Layout settles to the bottom (visible rect now catches up).
        _ = anchor.apply(contentHeight: 1800, visibleMaxY: 1800, isUserDriven: false)
        #expect(anchor.isNearBottom)

        // User deliberately scrolls up.
        _ = anchor.apply(contentHeight: 1800, visibleMaxY: 1200, isUserDriven: true)
        #expect(!anchor.isNearBottom)
    }
}
