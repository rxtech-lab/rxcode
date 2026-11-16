import AppKit
import ApplicationServices
import RxCodeCore

nonisolated struct PetDesktopWindow: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect // Global Quartz points: origin at the main display's top-left.
    let onScreen: Bool

    var label: String { "window_id=\(id) app=\(app) title=\(title) bounds=\(frame) on_screen=\(onScreen)" }
}

/// All potentially slow Accessibility IPC runs on this actor, away from the main actor.
actor PetDesktopDriver {
    func windows() -> [PetDesktopWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { return nil }
            return PetDesktopWindow(id: id, pid: pid, app: item[kCGWindowOwnerName as String] as? String ?? "Unknown",
                                    title: item[kCGWindowName as String] as? String ?? "", frame: frame,
                                    onScreen: item[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    func authorized(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func exactWindow(_ target: PetDesktopWindow, application: AXUIElement) throws -> AXUIElement {
        var elements = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        // Some browsers expose the selected window through focused/main/children while
        // AXWindows is empty. These references still require the same exact CG match.
        var alternatives = attribute(application, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = attribute(application, key), CFGetTypeID(value) == AXUIElementGetTypeID() {
                alternatives.append(value as! AXUIElement)
            }
        }
        for element in alternatives where attribute(element, kAXRoleAttribute) as? String == kAXWindowRole {
            if !elements.contains(where: { CFEqual($0, element) }) { elements.append(element) }
        }
        let candidates = elements.map { element in
            WindowCandidate(title: attribute(element, kAXTitleAttribute) as? String ?? "", frame: frame(element))
        }
        guard let index = Self.matchingWindowIndex(target: target, candidates: candidates) else {
            let details = candidates.prefix(8).map { "title=\($0.title.prefix(100)) bounds=\(String(describing: $0.frame))" }.joined(separator: "; ")
            throw IDEToolError.handlerFailed("Cannot uniquely map window_id=\(target.id) to an Accessibility window in pid=\(target.pid). Target title=\(target.title) bounds=\(target.frame); AX candidates: \(details); \(accessibilityDiagnostics(application)). No click, typing or scroll input was sent. List desktop targets and retry.")
        }
        if let axFrame = candidates[index].frame,
           abs(axFrame.minX - target.frame.minX) >= 3 || abs(axFrame.minY - target.frame.minY) >= 3 {
            // A position-independent match also needs a unique Quartz title/size in this PID.
            let peers = windows().filter {
                $0.pid == target.pid && $0.title == target.title
                    && abs($0.frame.width - target.frame.width) < 3 && abs($0.frame.height - target.frame.height) < 3
            }
            guard peers.count == 1, peers.first?.id == target.id else {
                throw IDEToolError.handlerFailed("Multiple off-screen windows share this title and size. No input was sent.")
            }
        }
        return elements[index]
    }

    private func accessibilityDiagnostics(_ application: AXUIElement) -> String {
        [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXChildrenAttribute].map { key in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, key as CFString, &value)
            let count = (value as? [AXUIElement])?.count
            return "\(key): error=\(error.rawValue), count=\(count.map(String.init) ?? "n/a")"
        }.joined(separator: "; ")
    }

    nonisolated struct WindowCandidate: Sendable {
        let title: String
        let frame: CGRect?
    }

    /// CG and AX titles can differ (for example Chrome's app suffix). A unique frame
    /// within the already selected PID identifies a window without trusting its title.
    /// Titles disambiguate overlapping frames. Off-screen position recovery additionally
    /// requires matching dimensions and a unique Quartz title/size within this PID.
    nonisolated static func matchingWindowIndex(target: PetDesktopWindow, candidates: [WindowCandidate]) -> Int? {
        let matches = candidates.indices.filter { index in
            guard let frame = candidates[index].frame else { return false }
            return abs(frame.minX - target.frame.minX) < 3 && abs(frame.minY - target.frame.minY) < 3
                && abs(frame.width - target.frame.width) < 3 && abs(frame.height - target.frame.height) < 3
        }
        if matches.count == 1 { return matches[0] }
        let titled = matches.filter { candidates[$0].title == target.title && !target.title.isEmpty }
        if titled.count == 1 { return titled[0] }
        guard matches.isEmpty, !target.onScreen, !target.title.isEmpty else { return nil }
        // Off-Space/minimized Quartz coordinates can differ from the restored AX position.
        // Chromium adds its app/profile suffix to AX titles. Never use a generic substring.
        let restored = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard let frame = candidate.frame,
                  candidate.title == target.title || candidate.title.hasPrefix(target.title + " - " + target.app) else { return false }
            return abs(frame.width - target.frame.width) < 3 && abs(frame.height - target.frame.height) < 3
        }
        return restored.count == 1 ? restored[0] : nil
    }

    /// Focus is an app/AX-window property, not a global Quartz z-order position.
    /// Other displays and floating windows can precede a focused target in that list.
    nonisolated static func focusedTarget(_ target: PetDesktopWindow, windows: [PetDesktopWindow],
                                         appFrontmost: Bool, exactAXWindowFocused: Bool) -> PetDesktopWindow? {
        guard appFrontmost, exactAXWindowFocused else { return nil }
        return windows.first { $0.id == target.id && $0.pid == target.pid && $0.onScreen }
    }

    func focus(_ target: PetDesktopWindow, excluding: Set<CGWindowID>) async throws -> PetDesktopWindow {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw IDEToolError.handlerFailed("Accessibility access is required.") }
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.6)
        // AXFrontmost alone does not reliably activate a hidden/background browser or
        // expose its AX windows. Native activation also participates in Space switching.
        let activated = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
            if app.isHidden { _ = app.unhide() }
            return app.activate(options: [])
        }
        var selectedWindow: AXUIElement?
        var mappingError: Error?
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard let fresh = windows().first(where: { $0.id == target.id && $0.pid == target.pid }) else {
                throw IDEToolError.handlerFailed("The selected window closed before it could be focused. No input was sent.")
            }
            do { selectedWindow = try exactWindow(fresh, application: application); break }
            catch { mappingError = error }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let window = selectedWindow else {
            throw mappingError ?? IDEToolError.handlerFailed("The selected window did not expose Accessibility information. No input was sent.")
        }
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true {
            guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw IDEToolError.handlerFailed("The specifically selected window could not be restored from the Dock.")
            }
        }
        try Task.checkCancellation()
        // Mark the exact window main before activating its process, then raise it again.
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw IDEToolError.handlerFailed("The application rejected raising this specific window.")
        }
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<30 {
            try Task.checkCancellation()
            let focused = attribute(application, kAXFocusedWindowAttribute)
            let frontmost = attribute(application, kAXFrontmostAttribute) as? Bool == true
            if let refreshed = Self.focusedTarget(target, windows: windows(), appFrontmost: frontmost,
                                                  exactAXWindowFocused: focused.map { CFEqual($0, window) } ?? false) {
                return refreshed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let focused = attribute(application, kAXFocusedWindowAttribute)
        let frontmost = attribute(application, kAXFrontmostAttribute) as? Bool == true
        let visible = windows().contains { $0.id == target.id && $0.onScreen }
        throw IDEToolError.handlerFailed("The exact target window did not become focused (native activation=\(activated), AX frontmost=\(frontmost), AX selected window=\(focused.map { CFEqual($0, window) } ?? false), on screen=\(visible)). No click or scroll was sent.")
    }

    func verifyFocused(_ target: PetDesktopWindow, excluding: Set<CGWindowID>) throws {
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.6)
        let window = try exactWindow(target, application: application)
        let focused = attribute(application, kAXFocusedWindowAttribute)
        guard Self.focusedTarget(target, windows: windows(),
                                 appFrontmost: attribute(application, kAXFrontmostAttribute) as? Bool == true,
                                 exactAXWindowFocused: focused.map { CFEqual($0, window) } ?? false) != nil else {
            throw IDEToolError.handlerFailed("The specifically selected window is no longer raised/focused. No further input was sent.")
        }
    }

    func typeText(_ text: String, into target: PetDesktopWindow, excluding: Set<CGWindowID>) async throws {
        let characters = Array(text)
        var expectedField: AXUIElement?
        for start in stride(from: 0, to: characters.count, by: 16) {
            try Task.checkCancellation()
            guard AXIsProcessTrusted() else { throw IDEToolError.handlerFailed("Accessibility access was revoked. Typing stopped.") }
            try verifyFocused(target, excluding: excluding)
            let application = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(application, 0.6)
            guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                throw IDEToolError.handlerFailed("No focused editable field is available. Click the intended text field first.")
            }
            let field = focused as! AXUIElement
            if let expectedField, !CFEqual(expectedField, field) { throw IDEToolError.handlerFailed("The focused text field changed. Typing stopped before sending further input.") }
            expectedField = field
            let role = attribute(field, kAXRoleAttribute) as? String ?? ""
            guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else {
                throw IDEToolError.handlerFailed("The focused element is not a supported editable field. No further text was typed.")
            }
            let units = Array(String(characters[start..<min(start + 16, characters.count)]).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw IDEToolError.handlerFailed("Could not create a native typing event.")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(65))
        }
    }

    nonisolated static func canIgnoreDockSurface(owner: String, layer: Int, frame: CGRect,
                                                 targetFrame: CGRect, exactAXHit: Bool) -> Bool {
        owner == "Dock" && layer == 20 && exactAXHit
            && frame.width >= targetFrame.width && frame.height >= targetFrame.height
    }

    func validate(_ target: PetDesktopWindow, point: CGPoint, excluding: Set<CGWindowID>) throws {
        guard AXIsProcessTrusted() else { throw IDEToolError.handlerFailed("Accessibility permission was revoked. No input was sent.") }
        guard let fresh = windows().first(where: { $0.id == target.id && $0.pid == target.pid && $0.onScreen }), fresh.frame == target.frame else {
            throw IDEToolError.handlerFailed("The target window moved, closed, or became unavailable. Retry with a fresh target.")
        }
        // Window bounds alone are not hit regions: Dock can own a full-display,
        // transparent surface. Ask AX which exact window is actually under the point.
        var hitSelectedWindow = false
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
           let hit {
            var hitPID: pid_t = 0
            if AXUIElementGetPid(hit, &hitPID) == .success, hitPID == target.pid {
                let application = AXUIElementCreateApplication(target.pid)
                AXUIElementSetMessagingTimeout(application, 0.6)
                let selected = try exactWindow(fresh, application: application)
                let value = attribute(hit, kAXWindowAttribute)
                let hitWindow: AXUIElement? = attribute(hit, kAXRoleAttribute) as? String == kAXWindowRole ? hit
                    : value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
                if let hitWindow { hitSelectedWindow = CFEqual(hitWindow, selected) }
                // If AX cannot identify a window, retain the conservative Quartz check below.
                if hitWindow != nil && !hitSelectedWindow {
                    throw IDEToolError.handlerFailed("A different window in the target app is under the input point. No input was sent.")
                }
            }
        }
        // Quartz lists are front to back. Include nonzero layers to catch menus/dialogs.
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw IDEToolError.handlerFailed("Could not verify the input target.")
        }
        for item in info {
            guard let id = item[kCGWindowNumber as String] as? UInt32, !excluding.contains(id),
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            guard id == target.id else {
                let owner = item[kCGWindowOwnerName as String] as? String ?? "Unknown"
                let layer = item[kCGWindowLayer as String] as? Int ?? 0
                // Ignore only Dock's display-sized surface when native hit testing proves
                // the exact selected window receives this point. Menus/other apps still block.
                if Self.canIgnoreDockSurface(owner: owner, layer: layer, frame: rect,
                                             targetFrame: fresh.frame, exactAXHit: hitSelectedWindow) { continue }
                throw IDEToolError.handlerFailed("Another window covers the requested point (window_id=\(id), app=\(owner), layer=\(layer), bounds=\(rect)). No input was sent.")
            }
            return
        }
        throw IDEToolError.handlerFailed("The requested window is not under the input point. No input was sent.")
    }

    func click(_ target: PetDesktopWindow, point: CGPoint, excluding: Set<CGWindowID>) throws {
        try Task.checkCancellation()
        try validate(target, point: point, excluding: excluding)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw IDEToolError.handlerFailed("Could not create native mouse events.")
        }
        // Do not suspend between down/up: cancellation must never leave the button held.
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func waitForInputTarget(_ target: PetDesktopWindow, point: CGPoint, excluding: Set<CGWindowID>) async throws {
        // AX focus can settle before the WindowServer's Dock/Space transition shield
        // disappears. Wait before the first event, never retry after partial scrolling.
        for attempt in 0..<25 {
            try Task.checkCancellation()
            do { try validate(target, point: point, excluding: excluding); return }
            catch {
                if attempt == 24 { throw error }
                try await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    func scroll(_ target: PetDesktopWindow, point: CGPoint, direction: String, amount: Int32, excluding: Set<CGWindowID>) async throws {
        try await waitForInputTarget(target, point: point, excluding: excluding)
        let steps: Int32 = 12
        var posted: Int32 = 0
        for index in 0..<steps {
            try Task.checkCancellation()
            try validate(target, point: point, excluding: excluding)
            let distance = index == steps - 1 ? amount - posted : amount / steps
            posted += distance
            let vertical = direction == "up" ? distance : direction == "down" ? -distance : 0
            let horizontal = direction == "left" ? distance : direction == "right" ? -distance : 0
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
                throw IDEToolError.handlerFailed("Could not create a native scroll event. Earlier scroll steps may have been delivered.")
            }
            event.location = point
            event.flags = []
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(35))
        }
    }
}
