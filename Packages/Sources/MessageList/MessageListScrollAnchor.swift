import CoreGraphics

nonisolated struct MessageListScrollAnchor: Equatable {
    var threshold: CGFloat
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

    /// Apply a new scroll geometry sample.
    ///
    /// `isUserDriven` reports whether the change is driven by the user's finger /
    /// trackpad (or post-flick glide) rather than by layout or a programmatic
    /// scroll. It gates the only branch that can *un-stick* the anchor — see
    /// below for why that matters.
    @discardableResult
    mutating func apply(contentHeight: CGFloat, visibleMaxY: CGFloat, isUserDriven: Bool) -> Decision {
        let distanceFromBottom = max(0, contentHeight - visibleMaxY)
        let nowNearBottom = distanceFromBottom < threshold

        guard hasReceivedFirstUpdate else {
            hasReceivedFirstUpdate = true
            lastContentHeight = contentHeight
            isNearBottom = nowNearBottom
            return .none
        }

        let grewEpsilon: CGFloat = 0.5
        let contentGrew = contentHeight > lastContentHeight + grewEpsilon
        let previouslyNearBottom = isNearBottom
        lastContentHeight = contentHeight

        if contentGrew {
            return previouslyNearBottom ? .scrollToBottom : .none
        }

        // Content stable (or shrunk). Recomputing `isNearBottom` from the raw
        // distance is the ONLY path that can un-stick the anchor, so it must
        // only run for a genuine user scroll. A tall card (Edit diff, Bash
        // output, etc.) that lays out in one frame leaves `distanceFromBottom`
        // huge until the throttled/async scroll-to-bottom executes; a layout
        // settle that lands in that window would otherwise recompute
        // `isNearBottom` to false even though the user never scrolled — which
        // then makes the pending auto-scroll bail and strands the view above
        // the bottom. Gating on `isUserDriven` keeps the anchor sticky through
        // that settle while still letting a deliberate scroll up release it.
        guard isUserDriven else { return .none }
        isNearBottom = nowNearBottom
        return .none
    }

    mutating func resetToBottom() {
        isNearBottom = true
    }
}
