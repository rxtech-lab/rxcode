import Testing
import CoreGraphics
@testable import RxCodeChatKit

/// `AutoScrollAnchor` decides whether content-growth events should pull the
/// scroll view back to the bottom and whether a given geometry change should
/// flip the user out of "anchored" mode. The original bug: a tall card
/// (Edit diff, Bash output) growing under the user briefly pushed
/// `distanceFromBottom` over the threshold, which the previous logic read as
/// "user scrolled up" — silently disabling auto-scroll for the rest of the
/// stream.
@Suite("AutoScrollAnchor")
struct AutoScrollAnchorTests {

    // MARK: - First update

    @Test("First geometry update initializes state from raw distance")
    func firstUpdateInitializesFromRawDistance() {
        var anchor = AutoScrollAnchor(threshold: 120)

        // Far from bottom on the very first sample → start un-anchored.
        let decision = anchor.apply(contentHeight: 1000, visibleMaxY: 500)
        #expect(decision == .none)
        #expect(anchor.isNearBottom == false)
        #expect(anchor.lastContentHeight == 1000)
    }

    @Test("First update at bottom keeps anchor true")
    func firstUpdateAtBottomKeepsAnchor() {
        var anchor = AutoScrollAnchor(threshold: 120)
        let decision = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        #expect(decision == .none)
        #expect(anchor.isNearBottom == true)
    }

    // MARK: - The bug under test: content grows under an anchored user

    @Test("Large card appearing while anchored requests scroll without un-sticking")
    func contentGrowthWhileAnchoredStaysSticky() {
        var anchor = AutoScrollAnchor(threshold: 120)
        // Establish baseline: user is glued to bottom (distance 0).
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        #expect(anchor.isNearBottom == true)

        // Edit card materializes — content height jumps 400pt, visible rect
        // hasn't been re-anchored yet. The new distanceFromBottom is 400,
        // well past the 120pt threshold. The old code flipped to false here.
        let decision = anchor.apply(contentHeight: 1400, visibleMaxY: 1000)
        #expect(decision == .scrollToBottom)
        #expect(anchor.isNearBottom == true, "growth alone must never un-stick the anchor")
    }

    @Test("Repeated growth keeps requesting scroll-to-bottom each tick")
    func repeatedGrowthKeepsRequestingScroll() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 500, visibleMaxY: 500)

        for height in stride(from: CGFloat(600), through: 2000, by: 100) {
            let decision = anchor.apply(contentHeight: height, visibleMaxY: 500)
            #expect(decision == .scrollToBottom, "tick at height \(height) should request scroll")
            #expect(anchor.isNearBottom == true)
        }
    }

    @Test("Content growth while user is scrolled up neither scrolls nor re-anchors")
    func growthWhileScrolledUpDoesNothing() {
        var anchor = AutoScrollAnchor(threshold: 120)
        // Baseline: user is anchored at bottom.
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        // User scrolls up 400pt (content size stable). This is a genuine
        // user gesture and must flip the anchor.
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 600)
        #expect(anchor.isNearBottom == false)

        // Now content grows: should NOT request a scroll (user chose to be
        // up here) and must NOT re-anchor them.
        let decision = anchor.apply(contentHeight: 1400, visibleMaxY: 600)
        #expect(decision == .none)
        #expect(anchor.isNearBottom == false)
    }

    // MARK: - User-driven scrolls (content stable)

    @Test("User scrolls up while content size is stable → un-anchor")
    func userScrollUpUnsticksAnchor() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        let decision = anchor.apply(contentHeight: 1000, visibleMaxY: 500)
        #expect(decision == .none)
        #expect(anchor.isNearBottom == false)
    }

    @Test("User scrolls back to bottom → re-anchor")
    func userScrollBackToBottomReanchors() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 500)
        #expect(anchor.isNearBottom == false)

        let decision = anchor.apply(contentHeight: 1000, visibleMaxY: 990)
        #expect(decision == .none)
        #expect(anchor.isNearBottom == true)
    }

    // MARK: - Threshold semantics

    @Test("Within threshold counts as near bottom")
    func withinThresholdIsNearBottom() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 950) // distance 50 < 120
        #expect(anchor.isNearBottom == true)
    }

    @Test("Just outside threshold counts as not near bottom")
    func justOutsideThresholdIsFar() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 850) // distance 150 > 120
        #expect(anchor.isNearBottom == false)
    }

    // MARK: - Sub-pixel jitter

    @Test("Sub-pixel height jitter is not treated as content growth")
    func subPixelJitterIgnored() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        // 0.3pt jitter: should fall through to the stable-content branch,
        // recomputing isNearBottom from raw distance (still ~0 → true).
        let decision = anchor.apply(contentHeight: 1000.3, visibleMaxY: 1000)
        #expect(decision == .none)
        #expect(anchor.isNearBottom == true)
    }

    // MARK: - resetToBottom

    @Test("resetToBottom re-anchors after a programmatic scroll")
    func resetToBottomReanchors() {
        var anchor = AutoScrollAnchor(threshold: 120)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 1000)
        _ = anchor.apply(contentHeight: 1000, visibleMaxY: 200) // user scrolled up
        #expect(anchor.isNearBottom == false)

        anchor.resetToBottom()
        #expect(anchor.isNearBottom == true)
    }

    // MARK: - End-to-end regression sequence

    /// Replays the exact failure mode the user reported: assistant streams text,
    /// then an Edit card finishes and grows the message height by ~400pt, then
    /// streaming continues. The anchor must stay glued to the bottom the entire
    /// time without the user touching the trackpad.
    @Test("Streaming + large Edit card → anchor never un-sticks")
    func streamingWithLargeCardRegression() {
        var anchor = AutoScrollAnchor(threshold: 120)

        // 1. Session loads, scroll lands at bottom.
        _ = anchor.apply(contentHeight: 800, visibleMaxY: 800)
        #expect(anchor.isNearBottom == true)

        // 2. Streaming text deltas grow content a few pixels at a time —
        //    SwiftUI's bottom anchor keeps visibleMaxY pinned to contentHeight.
        for height in [CGFloat(820), CGFloat(840), CGFloat(860), CGFloat(900)] {
            let decision = anchor.apply(contentHeight: height, visibleMaxY: height)
            #expect(decision == .scrollToBottom, "small growth at \(height) should still request scroll")
            #expect(anchor.isNearBottom == true)
        }

        // 3. The Edit tool result arrives — a tall diff card. Content height
        //    jumps from 900 to 1300, but SwiftUI hasn't re-anchored yet so the
        //    visible rect is still at 900. distanceFromBottom = 400 — way past
        //    the 120pt threshold. This is the moment the old code broke.
        let edit = anchor.apply(contentHeight: 1300, visibleMaxY: 900)
        #expect(edit == .scrollToBottom)
        #expect(anchor.isNearBottom == true)

        // 4. The programmatic scroll lands, visible rect catches up.
        let caught = anchor.apply(contentHeight: 1300, visibleMaxY: 1300)
        #expect(caught == .none)
        #expect(anchor.isNearBottom == true)

        // 5. More streaming text. Still anchored.
        let more = anchor.apply(contentHeight: 1340, visibleMaxY: 1340)
        #expect(more == .scrollToBottom)
        #expect(anchor.isNearBottom == true)
    }
}
