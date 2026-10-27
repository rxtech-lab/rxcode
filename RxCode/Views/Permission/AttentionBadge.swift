import RxCodeCore
import SwiftUI

struct AttentionBadge: View {
    let attention: PendingAttention

    var body: some View {
        if attention.count > 0 {
            Text(attention.count > 99 ? "99+" : String(attention.count))
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(ClaudeTheme.statusWarning, in: Capsule())
                .fixedSize()
                .help(attention.label)
                .accessibilityLabel(attention.label)
        }
    }
}

/// Adds the same badge beside the title in AppKit's native window tab bar.
struct WindowAttentionBadge: NSViewRepresentable {
    let attention: PendingAttention

    func makeNSView(context: Context) -> HostView { HostView() }

    func updateNSView(_ view: HostView, context: Context) {
        view.attention = attention
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.removeBadge()
    }

    final class HostView: NSView {
        var attention = PendingAttention() {
            didSet { updateBadge() }
        }
        private weak var badgeWindow: NSWindow?
        private let badgeView = NSHostingView(rootView: AttentionBadge(attention: PendingAttention()))

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            badgeView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                badgeView.widthAnchor.constraint(equalToConstant: 36),
                badgeView.heightAnchor.constraint(equalToConstant: 20),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if badgeWindow !== window { removeBadge() }
            updateBadge()
        }

        func removeBadge() {
            if let badgeWindow, badgeWindow.tab.accessoryView === badgeView {
                badgeWindow.tab.accessoryView = nil
            }
            badgeWindow = nil
        }

        private func updateBadge() {
            guard let window else { return }
            guard attention.count > 0 else {
                removeBadge()
                return
            }
            badgeWindow = window
            badgeView.rootView = AttentionBadge(attention: attention)
            badgeView.toolTip = attention.label
            if window.tab.accessoryView !== badgeView {
                window.tab.accessoryView = badgeView
            }
        }
    }
}
