import SwiftUI
import UIKit

/// A full-width list row button that ignores touches that moved.
///
/// A plain `Button` fires as long as the finger lifts inside it, and a vertical
/// `ScrollView` only claims vertical movement. A sideways or diagonal thumb
/// movement across a row therefore opened it. This button keeps the system
/// `Button` for its styling and accessibility and drops the action when the
/// finger travelled like a drag rather than a tap.
struct MobileRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var touch = MobileRowTouch()

    var body: some View {
        Button {
            guard !touch.movedRecently else { return }
            MobileHaptics.buttonTap()
            action()
        } label: {
            label()
        }
        .gesture(MobileRowTouchTracker(touch: touch))
    }
}

/// What the tracker saw. Not observable because nothing renders from it.
private final class MobileRowTouch {
    var movedAt: ContinuousClock.Instant?

    /// Bounded so a VoiceOver or Switch Control activation, which has no touch
    /// to reset this, still works after an earlier drag on the same row.
    var movedRecently: Bool {
        guard let movedAt else { return false }
        return movedAt.duration(to: .now) < .milliseconds(500)
    }
}

private struct MobileRowTouchTracker: UIGestureRecognizerRepresentable {
    let touch: MobileRowTouch

    func makeUIGestureRecognizer(context: Context) -> MobileRowTouchRecognizer {
        MobileRowTouchRecognizer(touch: touch)
    }
}

/// Observes touches and never recognizes, so it can't delay or block the button
/// or the enclosing scroll view.
private final class MobileRowTouchRecognizer: UIGestureRecognizer {
    /// Matches the distance at which a vertical `ScrollView` starts scrolling.
    private static let tapSlop: CGFloat = 10

    private let touch: MobileRowTouch
    private var start: CGPoint?
    private var didMove = false

    init(touch: MobileRowTouch) {
        self.touch = touch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, let first = touches.first else { return }
        // Window coordinates, because the row itself moves while scrolling.
        start = first.location(in: nil)
        didMove = false
        touch.movedAt = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !didMove, let start, let first = touches.first else { return }
        let location = first.location(in: nil)
        if hypot(location.x - start.x, location.y - start.y) > Self.tapSlop {
            didMove = true
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish()
    }

    override func reset() {
        start = nil
        didMove = false
    }

    private func finish() {
        // Stamped at lift, so pausing before lifting still counts as a drag.
        if didMove { touch.movedAt = .now }
        state = .failed
    }
}
