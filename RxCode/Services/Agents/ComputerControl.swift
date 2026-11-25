import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import RxCodeCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screen capture and synthetic input for the whole Mac, shared by agent
/// computer use and phone remote control. Coordinates are global Quartz
/// points: origin at the main display's top-left, y growing downward.
nonisolated enum ComputerControl {
    struct Display: Sendable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        /// Bounds in global Quartz points.
        let frame: CGRect
        let isMain: Bool
    }

    struct Capture: Sendable {
        let jpeg: Data
        /// Pixel size of the JPEG.
        let width: Int
        let height: Int
        let display: Display
        /// Pointer position as fractions of the display, when it is on it.
        let cursor: CGPoint?
    }

    enum ControlError: LocalizedError {
        case screenRecordingDenied
        case accessibilityDenied
        case displayUnavailable
        case encodingFailed
        case eventCreationFailed
        case invalidKey(String)

        var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                String(localized: "RxCode needs Screen Recording permission. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording.")
            case .accessibilityDenied:
                String(localized: "RxCode needs Accessibility permission to control the mouse and keyboard. Allow it in System Settings → Privacy & Security → Accessibility.")
            case .displayUnavailable: String(localized: "That display is not connected.")
            case .encodingFailed: String(localized: "The screenshot could not be encoded.")
            case .eventCreationFailed: String(localized: "macOS refused to create the input event.")
            case .invalidKey(let key): String(localized: "Unknown key combination: \(key)")
            }
        }
    }

    // MARK: Permissions

    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func hasAccessibilityAccess(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    // MARK: Displays

    static func displays() async -> [Display] {
        let names: [CGDirectDisplayID: String] = await MainActor.run {
            var names: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
                }
            }
            return names
        }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            Display(id: id, name: names[id] ?? String(localized: "Display \(id)"), frame: CGDisplayBounds(id), isMain: id == main)
        }
        .sorted { lhs, rhs in lhs.isMain != rhs.isMain ? lhs.isMain : lhs.frame.minX < rhs.frame.minX }
    }

    static func display(id: CGDirectDisplayID?) async throws -> Display {
        let all = await displays()
        if let id {
            guard let match = all.first(where: { $0.id == id }) else { throw ControlError.displayUnavailable }
            return match
        }
        guard let main = all.first else { throw ControlError.displayUnavailable }
        return main
    }

    // MARK: Capture

    /// One JPEG of a display, scaled so its longest edge is at most `maxDimension`.
    static func capture(
        displayID: CGDirectDisplayID?,
        maxDimension: Int,
        quality: Double,
        showsCursor: Bool
    ) async throws -> Capture {
        guard hasScreenRecordingAccess else { throw ControlError.screenRecordingDenied }
        let display = try await display(id: displayID)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ControlError.displayUnavailable
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let pixelWidth = display.frame.width * scale
        let pixelHeight = display.frame.height * scale
        let downscale = min(1, CGFloat(max(maxDimension, 320)) / max(pixelWidth, pixelHeight, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((pixelWidth * downscale).rounded()))
        configuration.height = max(1, Int((pixelHeight * downscale).rounded()))
        configuration.showsCursor = showsCursor
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let jpeg = encodeJPEG(image, quality: quality) else { throw ControlError.encodingFailed }
        return Capture(
            jpeg: jpeg, width: image.width, height: image.height, display: display,
            cursor: cursorFraction(in: display.frame)
        )
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The pointer as fractions of `frame`, or `nil` when it's elsewhere.
    static func cursorFraction(in frame: CGRect) -> CGPoint? {
        guard let location = CGEvent(source: nil)?.location, frame.contains(location), frame.width > 0, frame.height > 0 else {
            return nil
        }
        return CGPoint(x: (location.x - frame.minX) / frame.width, y: (location.y - frame.minY) / frame.height)
    }

    /// The global point at fractions `x`, `y` of `frame`, kept inside it.
    static func point(fractionX x: Double, y: Double, in frame: CGRect) -> CGPoint {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        return CGPoint(
            x: frame.minX + min(frame.width - 1, clampedX * frame.width),
            y: frame.minY + min(frame.height - 1, clampedY * frame.height)
        )
    }

    // MARK: Input

    private static func requireAccessibility() throws {
        guard hasAccessibilityAccess() else { throw ControlError.accessibilityDenied }
    }

    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    static func move(to point: CGPoint) throws {
        try requireAccessibility()
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw ControlError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, button: CGMouseButton = .left, count: Int = 1) async throws {
        try requireAccessibility()
        try move(to: point)
        try await Task.sleep(for: .milliseconds(30))
        let (downType, upType): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        for clickState in 1...max(1, min(count, 3)) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                throw ControlError.eventCreationFailed
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            // Never suspend between down and up: a cancel must not leave the button held.
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if clickState < count { try await Task.sleep(for: .milliseconds(60)) }
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint) async throws {
        try requireAccessibility()
        try move(to: start)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            throw ControlError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        defer {
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        let steps = 16
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    /// Scrolls by pixel deltas; positive `dy` moves content down (scrolls up).
    static func scroll(at point: CGPoint, dx: Int32, dy: Int32) async throws {
        try requireAccessibility()
        try move(to: point)
        let steps: Int32 = 8
        var sentX: Int32 = 0
        var sentY: Int32 = 0
        for index in 0..<steps {
            let stepX = index == steps - 1 ? dx - sentX : dx / steps
            let stepY = index == steps - 1 ? dy - sentY : dy / steps
            sentX += stepX
            sentY += stepY
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: stepY, wheel2: stepX, wheel3: 0) else {
                throw ControlError.eventCreationFailed
            }
            event.location = point
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Types `text` into whatever has keyboard focus.
    static func type(_ text: String) async throws {
        try requireAccessibility()
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            try Task.checkCancellation()
            let chunk = Array(units[start..<min(start + 16, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ControlError.eventCreationFailed
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Presses a combination such as `cmd+shift+t`.
    static func press(_ combination: String) throws {
        try requireAccessibility()
        guard let parsed = RemoteKey.parse(combination) else { throw ControlError.invalidKey(combination) }
        var flags: CGEventFlags = []
        if parsed.modifiers.contains("command") { flags.insert(.maskCommand) }
        if parsed.modifiers.contains("shift") { flags.insert(.maskShift) }
        if parsed.modifiers.contains("option") { flags.insert(.maskAlternate) }
        if parsed.modifiers.contains("control") { flags.insert(.maskControl) }
        if parsed.modifiers.contains("function") { flags.insert(.maskSecondaryFn) }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: parsed.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: parsed.code, keyDown: false) else {
            throw ControlError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
