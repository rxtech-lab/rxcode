import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Hosts a headless Chrome tab's rendered viewport and forwards mouse, scroll,
/// keyboard, and clipboard events to CDP.
struct ChromeBrowserView: NSViewRepresentable {
    let controller: ChromeTabController

    func makeNSView(context: Context) -> ChromeViewportNSView {
        let view = ChromeViewportNSView()
        view.attach(to: controller)
        return view
    }

    func updateNSView(_ view: ChromeViewportNSView, context: Context) {
        view.attach(to: controller)
    }

    static func dismantleNSView(_ view: ChromeViewportNSView, coordinator: ()) {
        view.detach()
    }
}

final class ChromeViewportNSView: NSView {
    private weak var controller: ChromeTabController?
    private var currentFrame: CGImage?
    private var currentLogicalSize: CGSize = .zero
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(to controller: ChromeTabController) {
        guard self.controller !== controller else { return }
        detach()
        self.controller = controller
        self.currentFrame = controller.latestFrame
        self.currentLogicalSize = controller.latestFrameLogicalSize
        controller.onFrame = { [weak self] image, logicalSize in
            guard let self else { return }
            self.currentFrame = image
            self.currentLogicalSize = logicalSize
            self.needsDisplay = true
        }
        syncVisibilityAndSize()
        needsDisplay = true
    }

    func detach() {
        controller?.onFrame = nil
        controller?.setVisible(false)
        controller = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncVisibilityAndSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncVisibilityAndSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncVisibilityAndSize()
    }

    private func syncVisibilityAndSize() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        controller?.setVisible(visible)
        if bounds.width >= 100, bounds.height >= 100 {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            controller?.updateViewport(size: bounds.size, scale: scale)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        guard let currentFrame else { return }
        let drawSize = currentLogicalSize.width > 0 && currentLogicalSize.height > 0
            ? currentLogicalSize
            : bounds.size
        let targetRect = CGRect(origin: .zero, size: drawSize)
        let image = NSImage(cgImage: currentFrame, size: drawSize)
        image.draw(in: targetRect, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: [
            .interpolation: NSNumber(value: NSImageInterpolation.high.rawValue),
        ])
    }

    // MARK: - Pointer Input

    private func viewportPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(local.x, 0), bounds.width),
            y: min(max(local.y, 0), bounds.height)
        )
    }

    private static func cdpModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.option) { mask |= 1 }
        if flags.contains(.control) { mask |= 2 }
        if flags.contains(.command) { mask |= 4 }
        if flags.contains(.shift) { mask |= 8 }
        return mask
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.dispatchMouse(
            type: "mousePressed",
            point: viewportPoint(for: event),
            button: "left",
            buttons: 1,
            clickCount: max(event.clickCount, 1),
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func mouseUp(with event: NSEvent) {
        controller?.dispatchMouse(
            type: "mouseReleased",
            point: viewportPoint(for: event),
            button: "left",
            buttons: 0,
            clickCount: max(event.clickCount, 1),
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.dispatchMouse(
            type: "mouseMoved",
            point: viewportPoint(for: event),
            button: "left",
            buttons: 1,
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.dispatchMouse(
            type: "mouseMoved",
            point: viewportPoint(for: event),
            button: "none",
            buttons: 0,
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.dispatchMouse(
            type: "mousePressed",
            point: viewportPoint(for: event),
            button: "right",
            buttons: 2,
            clickCount: max(event.clickCount, 1),
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        controller?.dispatchMouse(
            type: "mouseReleased",
            point: viewportPoint(for: event),
            button: "right",
            buttons: 0,
            clickCount: max(event.clickCount, 1),
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.dispatchMouse(
            type: "mousePressed",
            point: viewportPoint(for: event),
            button: "middle",
            buttons: 4,
            clickCount: max(event.clickCount, 1),
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        controller?.dispatchMouse(
            type: "mouseReleased",
            point: viewportPoint(for: event),
            button: "middle",
            buttons: 0,
            clickCount: max(event.clickCount, 1),
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: Double = event.hasPreciseScrollingDeltas ? 1.0 : 24.0
        let dx = -Double(event.scrollingDeltaX) * multiplier
        let dy = -Double(event.scrollingDeltaY) * multiplier
        guard dx != 0 || dy != 0 else { return }
        controller?.dispatchMouse(
            type: "mouseWheel",
            point: viewportPoint(for: event),
            modifiers: Self.cdpModifiers(from: event.modifierFlags),
            deltaX: dx,
            deltaY: dy
        )
    }

    // MARK: - Keyboard & Clipboard Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "c" where !flags.contains(.shift):
            controller?.copySelectionToPasteboard(cut: false)
            return true
        case "x" where !flags.contains(.shift):
            controller?.copySelectionToPasteboard(cut: true)
            return true
        case "v" where !flags.contains(.shift):
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                controller?.insertText(text)
            }
            return true
        case "a" where !flags.contains(.shift):
            controller?.dispatchKey(
                type: "rawKeyDown",
                key: "a",
                code: "KeyA",
                windowsVirtualKeyCode: 65,
                modifiers: 4,
                commands: ["selectAll"]
            )
            return true
        case "z":
            let command = flags.contains(.shift) ? "redo" : "undo"
            controller?.dispatchKey(
                type: "rawKeyDown",
                key: "z",
                code: "KeyZ",
                windowsVirtualKeyCode: 90,
                modifiers: flags.contains(.shift) ? 12 : 4,
                commands: [command]
            )
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let info = Self.mapKey(event)
        let modifiers = Self.cdpModifiers(from: event.modifierFlags)
        let hasText = info.text?.isEmpty == false && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)
        controller?.dispatchKey(
            type: hasText ? "keyDown" : "rawKeyDown",
            key: info.key,
            code: info.code,
            text: hasText ? info.text : nil,
            unmodifiedText: hasText ? info.unmodifiedText : nil,
            windowsVirtualKeyCode: info.vkCode,
            modifiers: modifiers
        )
    }

    override func keyUp(with event: NSEvent) {
        let info = Self.mapKey(event)
        controller?.dispatchKey(
            type: "keyUp",
            key: info.key,
            code: info.code,
            windowsVirtualKeyCode: info.vkCode,
            modifiers: Self.cdpModifiers(from: event.modifierFlags)
        )
    }

    private struct KeyMapping {
        let key: String
        let code: String
        let vkCode: Int
        let text: String?
        let unmodifiedText: String?
    }

    private static func mapKey(_ event: NSEvent) -> KeyMapping {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return KeyMapping(key: "Enter", code: "Enter", vkCode: 13, text: "\r", unmodifiedText: "\r")
        case kVK_Tab:
            return KeyMapping(key: "Tab", code: "Tab", vkCode: 9, text: nil, unmodifiedText: nil)
        case kVK_Delete:
            return KeyMapping(key: "Backspace", code: "Backspace", vkCode: 8, text: nil, unmodifiedText: nil)
        case kVK_ForwardDelete:
            return KeyMapping(key: "Delete", code: "Delete", vkCode: 46, text: nil, unmodifiedText: nil)
        case kVK_Escape:
            return KeyMapping(key: "Escape", code: "Escape", vkCode: 27, text: nil, unmodifiedText: nil)
        case kVK_LeftArrow:
            return KeyMapping(key: "ArrowLeft", code: "ArrowLeft", vkCode: 37, text: nil, unmodifiedText: nil)
        case kVK_UpArrow:
            return KeyMapping(key: "ArrowUp", code: "ArrowUp", vkCode: 38, text: nil, unmodifiedText: nil)
        case kVK_RightArrow:
            return KeyMapping(key: "ArrowRight", code: "ArrowRight", vkCode: 39, text: nil, unmodifiedText: nil)
        case kVK_DownArrow:
            return KeyMapping(key: "ArrowDown", code: "ArrowDown", vkCode: 40, text: nil, unmodifiedText: nil)
        case kVK_Home:
            return KeyMapping(key: "Home", code: "Home", vkCode: 36, text: nil, unmodifiedText: nil)
        case kVK_End:
            return KeyMapping(key: "End", code: "End", vkCode: 35, text: nil, unmodifiedText: nil)
        case kVK_PageUp:
            return KeyMapping(key: "PageUp", code: "PageUp", vkCode: 33, text: nil, unmodifiedText: nil)
        case kVK_PageDown:
            return KeyMapping(key: "PageDown", code: "PageDown", vkCode: 34, text: nil, unmodifiedText: nil)
        case kVK_Space:
            return KeyMapping(key: " ", code: "Space", vkCode: 32, text: " ", unmodifiedText: " ")
        default:
            let chars = event.characters ?? ""
            let unmodified = event.charactersIgnoringModifiers ?? chars
            let printable = chars.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } && !chars.isEmpty
            let vk = unmodified.uppercased().unicodeScalars.first.map { Int($0.value) } ?? 0
            let key = printable ? chars : (unmodified.isEmpty ? "Unidentified" : unmodified)
            let code: String
            if let scalar = unmodified.uppercased().unicodeScalars.first, (65...90).contains(scalar.value) {
                code = "Key\(Character(scalar))"
            } else if let scalar = unmodified.unicodeScalars.first, (48...57).contains(scalar.value) {
                code = "Digit\(Character(scalar))"
            } else {
                code = ""
            }
            return KeyMapping(
                key: key,
                code: code,
                vkCode: vk,
                text: printable ? chars : nil,
                unmodifiedText: printable ? unmodified : nil
            )
        }
    }
}
