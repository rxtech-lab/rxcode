import AppKit
import RxCodeCore
import SwiftUI

/// A persistent, pet-owned dialog. Transient popovers close when their anchor window moves.
struct PetPresentationPanel<Content: View>: NSViewRepresentable {
    let id: UUID?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> PetPresentationAnchorView { PetPresentationAnchorView() }

    func updateNSView(_ view: PetPresentationAnchorView, context: Context) {
        view.update(id: id, content: AnyView(content().id(id).appThemeForeground()))
    }

    static func dismantleNSView(_ view: PetPresentationAnchorView, coordinator: ()) {
        view.tearDown()
    }
}

private final class PetDialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Escape and focus changes must not act as the presentation's Close button.
    override func cancelOperation(_ sender: Any?) {}
}

@MainActor
final class PetPresentationAnchorView: NSView {
    private(set) var presentationPanel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var presentationID: UUID?
    private var updatePending = false

    func update(id: UUID?, content: AnyView) {
        guard let id else { tearDown(); return }
        presentationID = id
        if let hosting {
            hosting.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            hosting = host
        }
        schedulePosition()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(parentGeometryChanged), name: name, object: window)
            }
            schedulePosition()
        } else {
            detachPanel()
        }
    }

    override func layout() {
        super.layout()
        schedulePosition()
    }

    @objc private func parentGeometryChanged(_ notification: Notification) { schedulePosition() }

    private func schedulePosition() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.positionPanel()
        }
    }

    /// Reposition the same native window and hosting view so form and scroll state survive movement.
    func positionPanel() {
        guard presentationID != nil, let parent = window, let hosting else { return }
        let anchor = parent.convertToScreen(convert(bounds, to: nil))
        guard let visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? parent.screen)?.visibleFrame else { return }
        if presentationPanel == nil {
            let panel = PetDialogPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = hosting
            presentationPanel = panel
        }
        guard let panel = presentationPanel else { return }
        if panel.parent != parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        let fitting = hosting.fittingSize
        let size = CGSize(width: min(max(1, fitting.width), visible.width), height: min(max(1, fitting.height), visible.height))
        let frame = Self.presentationFrame(anchor: anchor, size: size, visible: visible)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if parent.isVisible && !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func presentationFrame(anchor: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let above = anchor.maxY + 12
        let y = above + size.height <= visible.maxY ? above : anchor.minY - size.height - 12
        return CGRect(x: min(max(visible.minX, anchor.midX - size.width / 2), max(visible.minX, visible.maxX - size.width)),
                      y: min(max(visible.minY, y), max(visible.minY, visible.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private func detachPanel() {
        guard let panel = presentationPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func tearDown() {
        detachPanel()
        presentationPanel?.contentView = nil
        presentationPanel = nil
        hosting = nil
        presentationID = nil
    }
}
