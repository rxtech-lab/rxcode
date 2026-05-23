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

    @discardableResult
    mutating func apply(contentHeight: CGFloat, visibleMaxY: CGFloat) -> Decision {
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

        isNearBottom = nowNearBottom
        return .none
    }

    mutating func resetToBottom() {
        isNearBottom = true
    }
}
