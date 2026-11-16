import AppKit
import RxCodeCore
import SwiftUI

// MARK: - Non-Activating Floating Desktop NSPanel

private final class FloatingPetPanel: NSPanel {
    var acceptsKeyInput = false
    override var canBecomeKey: Bool { acceptsKeyInput }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetPanelController {
    private unowned let controller: PetController
    private var panel: FloatingPetPanel?
    private var widgetPanel: FloatingPetPanel?
    private(set) var statusSize = NSSize(width: 1, height: 1)
    private var captionHeight: CGFloat = 160
    private var isTravelling = false
    private var spriteCenterInPanel: CGPoint?
    private var panelLayoutPending = false
    private var layoutShrinkTask: Task<Void, Never>?
    private var pendingShrinkSize: NSSize?
    private var widgetPositionPending = false

    init(controller: PetController) {
        self.controller = controller
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private var ownedWindows: [NSWindow] {
        var result: [NSWindow] = []
        var seen: Set<Int> = []
        func add(_ window: NSWindow) {
            guard seen.insert(window.windowNumber).inserted else { return }
            result.append(window)
            for child in window.childWindows ?? [] { add(child) }
        }
        for window in [panel, widgetPanel].compactMap({ $0 }) { add(window) }
        return result
    }

    var photoWindowIDs: Set<CGWindowID> { Set(ownedWindows.map { CGWindowID($0.windowNumber) }) }

    var currentDisplayID: CGDirectDisplayID? {
        guard let panel else { return nil }
        // The sprite sits near the bottom-center, below its caption and tool bubbles.
        let center = spriteCenterInPanel ?? CGPoint(x: panel.frame.width / 2, y: spriteAnchorHeight)
        let anchor = CGPoint(x: panel.frame.minX + center.x, y: panel.frame.minY + center.y)
        return NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.petDisplayID
            ?? panel.screen?.petDisplayID
    }

    private var spriteAnchorHeight: CGFloat {
        CGFloat(controller.configuration.petSize) / 2 + 44 + 60
    }

    func updateSpriteFrame(_ frame: CGRect) {
        guard let panel, frame.width > 0, frame.height > 0 else { return }
        spriteCenterInPanel = CGPoint(x: frame.midX, y: panel.frame.height - frame.midY)
        // Geometry callbacks run during SwiftUI layout. Move child windows only
        // after that pass has finished, using the latest measured anchor.
        guard !widgetPositionPending else { return }
        widgetPositionPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.widgetPositionPending = false
            self.positionWidget()
        }
    }

    func hideForPhoto() -> [NSWindow] {
        let windows = ownedWindows.filter(\.isVisible)
        windows.forEach { $0.orderOut(nil) }
        return windows
    }

    func restoreAfterPhoto(_ windows: [NSWindow]) {
        guard controller.configuration.isEnabled else { return }
        windows.forEach { $0.orderFrontRegardless() }
    }

    func walk(to screen: NSScreen, above window: CGRect? = nil, at point: CGPoint? = nil) async throws {
        guard let panel else { throw IDEToolError.notSupported("The desktop pet is not visible.") }
        let start = panel.frame.origin
        let frame = screen.visibleFrame
        let target: CGPoint
        if let point {
            let anchor = spriteCenterInPanel ?? CGPoint(x: panel.frame.width / 2, y: spriteAnchorHeight)
            target = CGPoint(x: min(max(frame.minX, point.x - anchor.x), max(frame.minX, frame.maxX - panel.frame.width)),
                             y: min(max(frame.minY, point.y - anchor.y), max(frame.minY, frame.maxY - panel.frame.height)))
        } else { target = Self.photoOrigin(visibleFrame: frame, panelSize: panel.frame.size, window: window) }
        let distance = hypot(target.x - start.x, target.y - start.y)
        guard distance > 2 else { return }
        controller.isFacingLeft = target.x < start.x
        controller.setWalking(true)
        isTravelling = true
        defer {
            isTravelling = false
            controller.setWalking(false)
            // A cancelled trip or an unplugged monitor must not strand the pet in a desktop gap.
            panel.setFrameOrigin(clampedOrigin(panel.frame.origin, size: panel.frame.size))
        }
        // About 420 points per second; never teleport across the desktop.
        let duration = max(0.3, distance / 420)
        let began = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            guard NSScreen.screens.contains(where: { $0.petDisplayID == screen.petDisplayID }) else {
                throw IDEToolError.notSupported("The target display disconnected while walking.")
            }
            let elapsed = began.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let progress = min(1, seconds / duration)
            // Ease acceleration/deceleration without changing the path.
            let t = progress * progress * (3 - 2 * progress)
            panel.setFrameOrigin(CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
            positionWidget()
            if progress >= 1 { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        persistCurrentOrigin()
    }

    static func photoOrigin(visibleFrame: CGRect, panelSize: CGSize, window: CGRect?) -> CGPoint {
        let desiredX = (window?.midX ?? visibleFrame.midX) - panelSize.width / 2
        let desiredY = window.map { $0.maxY + 8 } ?? visibleFrame.minY + 28
        return CGPoint(x: min(max(visibleFrame.minX, desiredX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)),
                       y: min(max(visibleFrame.minY, desiredY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)))
    }

    func show() {
        guard !AppSupport.isTestProcess && !AppSupport.isScreenshotCapture else { return }
        if let panel {
            updatePanelLayout()
            panel.orderFrontRegardless()
            positionWidget()
            return
        }

        let size = desiredPanelSize()
        let origin = initialOrigin(for: size)
        let newPanel = FloatingPetPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.hidesOnDeactivate = false
        newPanel.isMovableByWindowBackground = false

        let rootView = PetOverlayView(
            controller: controller,
            onDragDelta: { [weak self] delta in
                self?.movePanel(by: delta)
            },
            onDragEnded: { [weak self] in
                self?.persistCurrentOrigin()
            },
            onCaptionHeightChange: { [weak self] height in
                self?.updateCaptionHeight(height)
            }
        )
        newPanel.contentView = Self.fixedSizeContent(rootView: rootView, size: size)

        self.panel = newPanel
        updatePanelLayout()
        newPanel.orderFrontRegardless()
        positionWidget()
    }

    func hide() {
        controller.screenCapture.cancel()
        controller.desktopActions.cancel()
        Task { _ = await controller.music.off() }
        widgetPanel?.orderOut(nil)
        panel?.orderOut(nil)
    }

    private func updateCaptionHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(captionHeight - height) > 1 else { return }
        captionHeight = height
        updatePanelLayout()
    }

    func updatePanelLayout() {
        // onChange and caption measurements can arrive inside a hosting view's
        // constraint pass. Coalesce them before touching the AppKit window.
        guard !panelLayoutPending else { return }
        panelLayoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelLayoutPending = false
            self.applyPanelLayout()
        }
    }

    private func applyPanelLayout() {
        guard let panel else { return }
        defer { positionWidget() }
        let newSize = desiredPanelSize()
        if pendingShrinkSize == newSize { return }
        layoutShrinkTask?.cancel()
        pendingShrinkSize = nil
        // Leave room for SwiftUI's outgoing caption/tool transition before clipping the window.
        if newSize.height < panel.frame.height - 1,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pendingShrinkSize = newSize
            layoutShrinkTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
                guard let self, let panel = self.panel else { return }
                self.pendingShrinkSize = nil
                self.resizePanel(panel, to: self.desiredPanelSize())
                self.positionWidget()
            }
            return
        }
        resizePanel(panel, to: newSize)
    }

    private func resizePanel(_ panel: NSPanel, to newSize: NSSize) {
        var frame = panel.frame
        if abs(frame.width - newSize.width) > 1 || abs(frame.height - newSize.height) > 1 {
            // Keep the bottom-center of the pet anchored when the speech bubble grows/shrinks
            let bottomCenterX = frame.midX
            let bottomY = frame.minY
            frame.size = newSize
            frame.origin.x = bottomCenterX - newSize.width / 2
            frame.origin.y = bottomY
            if !isTravelling { frame.origin = clampedOrigin(frame.origin, size: newSize) }
            panel.setFrame(frame, display: false)
        }
    }

    private static func fixedSizeContent<Content: View>(rootView: Content, size: NSSize) -> NSView {
        // Keep NSHostingView out of the window's content sizing negotiation.
        // Both views follow the controller's frame without Auto Layout constraints.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        // A bare NSHostingView sits outside any SwiftUI Scene, so `scenePhase` is stuck at
        // `.background`, which made PetSpriteView render a single still frame forever.
        // The always-on-screen panel is effectively active; pausing is handled by
        // `isAnimationActive` and the screen sleep/wake notifications instead.
        let hosting = NSHostingView(rootView: rootView.environment(\.scenePhase, .active))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }

    private func desiredPanelSize() -> NSSize {
        let petSide = CGFloat(controller.configuration.petSize)
        let hasTools = !controller.toolActivity.calls.isEmpty
        let largeBubble = controller.presentation.images.contains(where: { $0.id == controller.presentation.expandedID && $0.style == "bubble" })
        let hasEntries = !controller.presentation.images.isEmpty
            || controller.appState?.agentPrompts.dialogs.contains(where: { $0.isPetPresentation && !$0.usesPetCaption }) == true
        let width = max(largeBubble ? 460 : 260, petSide + 244)
        let hasBubble = controller.petState.bubble != nil
            || controller.actionStatusOverlayMessage != nil
            || !controller.livePartialUserText.isEmpty
        let hasCaptionUI = controller.appState?.agentPrompts.dialogs.contains { $0.id == controller.presentation.expandedID && $0.usesPetCaption } == true
        let bubbleAllowance: CGFloat = hasBubble ? captionHeight + 12 : 24
        let height = petSide + (hasCaptionUI ? 106 : 0) + 82 + (hasEntries ? 50 : 0) + bubbleAllowance + 60 + (hasTools ? 60 : 0) + (controller.music.showsPlayer ? 90 : 0) + (largeBubble ? 380 : 0)
        let visible = NSScreen.screens.first(where: { $0.petDisplayID == currentDisplayID })?.visibleFrame ?? NSScreen.main?.visibleFrame
        panel?.acceptsKeyInput = largeBubble
        return NSSize(width: min(width, visible?.width ?? width), height: min(height, visible?.height ?? height))
    }

    private func movePanel(by delta: CGSize) {
        guard let panel else { return }
        var origin = panel.frame.origin
        origin.x += delta.width
        origin.y += delta.height
        origin = clampedOrigin(origin, size: panel.frame.size)
        panel.setFrameOrigin(origin)
        positionWidget()
    }

    /// Ignore input without hiding the action animation. Include popovers and the widget.
    func ignoreInputForAction() -> [(NSWindow, Bool)] {
        let windows = ownedWindows
        let state = windows.map { ($0 as NSWindow, $0.ignoresMouseEvents) }
        windows.forEach { $0.ignoresMouseEvents = true }
        return state
    }

    func restoreInputAfterAction(_ state: [(NSWindow, Bool)]) {
        state.forEach { $0.0.ignoresMouseEvents = $0.1 }
    }

    /// Geometry arrives during SwiftUI layout; defer native sizing to avoid resize recursion.
    func updateStatusSize(_ measured: CGSize) {
        let size = NSSize(width: max(1, ceil(measured.width)), height: max(1, ceil(measured.height)))
        guard size != statusSize else { return }
        statusSize = size
        guard !widgetPositionPending else { return }
        widgetPositionPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.widgetPositionPending = false
            self.positionWidget()
        }
    }

    private func positionWidget() {
        guard let panel, panel.isVisible, controller.configuration.isEnabled, controller.presentation.widget != nil else {
            widgetPanel?.orderOut(nil)
            return
        }
        if widgetPanel == nil {
            let accessory = FloatingPetPanel(contentRect: CGRect(origin: .zero, size: statusSize),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            accessory.isOpaque = false
            accessory.backgroundColor = .clear
            accessory.level = .floating
            accessory.hasShadow = true
            accessory.hidesOnDeactivate = false
            accessory.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            accessory.contentView = Self.fixedSizeContent(
                rootView: PetStatusWidgetView(controller: controller, onSizeChange: { [weak self] size in
                    self?.updateStatusSize(size)
                }),
                size: statusSize
            )
            widgetPanel = accessory
            panel.addChildWindow(accessory, ordered: .above)
        }
        guard let accessory = widgetPanel else { return }
        let anchor = spriteCenterInPanel ?? CGPoint(x: panel.frame.width / 2, y: spriteAnchorHeight)
        let center = CGPoint(x: panel.frame.minX + anchor.x, y: panel.frame.minY + anchor.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: min(statusSize.width, visible.width), height: min(statusSize.height, visible.height))
        if accessory.frame.size != size {
            accessory.setContentSize(size)
            accessory.contentView?.frame = CGRect(origin: .zero, size: size)
        }
        let right = center.x + CGFloat(controller.configuration.petSize) / 2 + 12
        let desiredX = right + size.width <= visible.maxX ? right : center.x - CGFloat(controller.configuration.petSize) / 2 - 12 - size.width
        let origin = CGPoint(x: min(max(visible.minX, desiredX), max(visible.minX, visible.maxX - size.width)),
                             y: min(max(visible.minY, center.y - size.height / 2), max(visible.minY, visible.maxY - size.height)))
        if accessory.frame.origin != origin { accessory.setFrameOrigin(origin) }
        if !accessory.isVisible { accessory.orderFrontRegardless() }
    }

    private func persistCurrentOrigin() {
        guard let panel else { return }
        let frame = panel.frame
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame, visible.width > 0, visible.height > 0 else { return }
        let normX = Double((frame.midX - visible.minX) / visible.width)
        let normY = Double((frame.minY - visible.minY) / visible.height)
        controller.configuration.normalizedScreenX = min(0.98, max(0.02, normX))
        controller.configuration.normalizedScreenY = min(0.95, max(0.02, normY))
    }

    private func initialOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSPoint(x: 120, y: 120)
        }
        if let nx = controller.configuration.normalizedScreenX,
           let ny = controller.configuration.normalizedScreenY {
            let midX = visible.minX + CGFloat(nx) * visible.width
            let minY = visible.minY + CGFloat(ny) * visible.height
            return clampedOrigin(NSPoint(x: midX - size.width / 2, y: minY), size: size)
        }
        // Default bottom-right corner with comfortable margin above the Dock
        let defaultOrigin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.minY + 28
        )
        return clampedOrigin(defaultOrigin, size: size)
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let center = NSPoint(x: origin.x + size.width / 2,
                             y: origin.y + (spriteCenterInPanel?.y ?? spriteAnchorHeight))
        let matchingScreen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.min { lhs, rhs in
                hypot(lhs.frame.midX - center.x, lhs.frame.midY - center.y)
                    < hypot(rhs.frame.midX - center.x, rhs.frame.midY - center.y)
            }
            ?? NSScreen.screens.first
        guard let visible = matchingScreen?.visibleFrame else { return origin }
        let x = min(max(visible.minX, origin.x), max(visible.minX, visible.maxX - size.width))
        let y = min(max(visible.minY, origin.y), max(visible.minY, visible.maxY - size.height))
        return NSPoint(x: x, y: y)
    }
}
