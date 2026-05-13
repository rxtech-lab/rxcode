import CoreGraphics

/// Tracks whether the message list should stay anchored to the bottom across
/// scroll geometry updates.
///
/// The previous implementation derived `isNearBottom` directly from
/// `distanceFromBottom < threshold` on every geometry update. That fails when
/// a tall card (Edit diff, Bash output, etc.) appears mid-stream: the content
/// height grows in one frame, the visible rect hasn't been re-anchored yet,
/// so `distanceFromBottom` briefly exceeds the threshold and `isNearBottom`
/// flips to `false`. Subsequent structure-change callbacks then skip the
/// auto-scroll, stranding the user above the bottom even though they never
/// scrolled away.
///
/// `AutoScrollAnchor` separates the two sources of geometry change:
///   * Content height grew → keep `isNearBottom` sticky; emit `.scrollToBottom`
///     when the user was previously anchored. Growth alone never un-sticks.
///   * Content height stable → user-driven scroll; recompute `isNearBottom`
///     from the raw distance.
nonisolated struct AutoScrollAnchor: Equatable {
    /// Pixels from the bottom edge that still count as "anchored".
    var threshold: CGFloat
    /// Whether auto-scroll should follow the bottom on the next content growth.
    private(set) var isNearBottom: Bool
    private(set) var lastContentHeight: CGFloat
    private var hasReceivedFirstUpdate: Bool

    enum Decision: Equatable {
        case none
        case scrollToBottom
    }

    init(threshold: CGFloat = 120, isNearBottom: Bool = true) {
        self.threshold = threshold
        self.isNearBottom = isNearBottom
        self.lastContentHeight = 0
        self.hasReceivedFirstUpdate = false
    }

    /// Apply a new scroll geometry sample. Returns whether the caller should
    /// programmatically scroll to the bottom in response.
    @discardableResult
    mutating func apply(contentHeight: CGFloat, visibleMaxY: CGFloat) -> Decision {
        let distance = max(0, contentHeight - visibleMaxY)
        let nowNearBottom = distance < threshold

        guard hasReceivedFirstUpdate else {
            hasReceivedFirstUpdate = true
            lastContentHeight = contentHeight
            isNearBottom = nowNearBottom
            return .none
        }

        // Treat sub-pixel jitter as no change so floating-point noise doesn't
        // misclassify a layout pass as content growth.
        let grewEpsilon: CGFloat = 0.5
        let contentGrew = contentHeight > lastContentHeight + grewEpsilon
        let previouslyNearBottom = isNearBottom
        lastContentHeight = contentHeight

        if contentGrew {
            // Card expanded mid-stream. Keep the anchor sticky — the user did
            // not scroll, the document grew underneath them. Request a scroll
            // when they were anchored, otherwise leave their position alone.
            return previouslyNearBottom ? .scrollToBottom : .none
        }

        // Content stable (or shrunk): trust the geometry. This is the only
        // path that can un-stick the anchor, so a deliberate user scroll up
        // still flips `isNearBottom` to false.
        isNearBottom = nowNearBottom
        return .none
    }

    /// Force the anchor back to the bottom — used when the caller knows it
    /// just scrolled programmatically (session switch, send, etc.).
    mutating func resetToBottom() {
        isNearBottom = true
    }
}

/// Equatable snapshot of the two geometry values `AutoScrollAnchor` consumes.
/// `onScrollGeometryChange` only forwards updates when its mapped value
/// changes, so wrapping these in a value type keeps every relevant tick.
nonisolated struct ScrollSample: Equatable {
    var contentHeight: CGFloat
    var visibleMaxY: CGFloat
}

