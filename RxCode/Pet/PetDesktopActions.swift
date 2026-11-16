import AppKit
import Observation
import RxCodeCore

@MainActor @Observable
final class PetDesktopActions {
    private unowned let controller: PetController
    private let driver = PetDesktopDriver()
    private var operation: Task<JSONValue, Error>?
    private var generation = UUID()
    var animation: String?
    var permissionIssue = false
    var authorizationGranted = false
    var isCheckingAuthorization = false

    init(controller: PetController) { self.controller = controller }

    func cancel() {
        generation = UUID()
        operation?.cancel()
    }

    func cancelAndWait() async {
        let pending = operation
        cancel()
        _ = try? await pending?.value
    }

    func refreshAuthorization(prompt: Bool = false) async {
        guard !isCheckingAuthorization else { return }
        isCheckingAuthorization = true
        defer { isCheckingAuthorization = false }
        authorizationGranted = await driver.authorized(prompt: prompt)
        if authorizationGranted { permissionIssue = false }
    }

    func requestAccess() async {
        await refreshAuthorization(prompt: true)
        permissionIssue = !authorizationGranted
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func listTargets() async -> JSONValue {
        authorizationGranted = await driver.authorized(prompt: false)
        let windows = await driver.windows().filter { !controller.panelController.photoWindowIDs.contains($0.id) }
        let displays = NSScreen.screens.map { "display_id=\($0.petDisplayID) name=\($0.localizedName) Quartz_bounds=\(CGDisplayBounds($0.petDisplayID))" }
        return PetPresentation.result("targets", "Accessibility authorized=\(authorizationGranted). Coordinates for actions are normalized top-left fractions of the chosen window/display. Window titles may require Screen Recording permission.\n" + displays.joined(separator: "\n") + "\n" + windows.map(\.label).joined(separator: "\n"))
    }

    func run(_ action: String, arguments: JSONValue) async throws -> JSONValue {
        let previous = operation
        cancel()
        let token = generation
        await controller.screenCapture.cancelAndWait()
        _ = try? await previous?.value
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        let task = Task { try await self.perform(action, arguments: arguments) }
        operation = task
        return try await withTaskCancellationHandler {
            defer { if token == generation { operation = nil } }
            return try await task.value
        } onCancel: { task.cancel() }
    }

    private func perform(_ action: String, arguments: JSONValue) async throws -> JSONValue {
        guard controller.configuration.isEnabled else { throw IDEToolError.handlerFailed("Enable the desktop pet first.") }
        // Resolve and validate all arguments before prompting or changing the desktop.
        let id = try PetScreenCapture.identifier(arguments["window_id"])
        let displayID = try PetScreenCapture.identifier(arguments["display_id"])
        let query = arguments["window_query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard arguments["window_query"] == nil || query?.isEmpty == false,
              [id != nil, displayID != nil, query != nil].filter({ $0 }).count == 1 else {
            throw IDEToolError.invalidArguments("Choose exactly one window_id, window_query or display_id. Resolve ambiguous targets with ide__pet_list_desktop_targets.")
        }
        guard !["focus", "type"].contains(action) || displayID == nil else { throw IDEToolError.invalidArguments("Focusing and typing require a specific window.") }
        let x = try Self.fraction(arguments["x"], fallback: action == "click" ? nil : 0.5)
        let y = try Self.fraction(arguments["y"], fallback: action == "click" ? nil : 0.5)
        let direction = arguments["direction"]?.stringValue ?? "down"
        guard action != "scroll" || ["up", "down", "left", "right"].contains(direction) else {
            throw IDEToolError.invalidArguments("direction must be up, down, left or right.")
        }
        let text = arguments["text"]?.stringValue ?? ""
        if action == "type" && (text.isEmpty || text.count > 4000) { throw IDEToolError.invalidArguments("text must contain 1...4000 characters.") }
        let rawAmount = arguments["amount"]?.numberValue ?? 400
        guard arguments["amount"] == nil || arguments["amount"]?.numberValue != nil,
              rawAmount.isFinite, (1...1200).contains(rawAmount), rawAmount.rounded() == rawAmount else {
            throw IDEToolError.invalidArguments("amount must be an integer from 1 to 1200.")
        }
        let windows = await driver.windows().filter { !controller.panelController.photoWindowIDs.contains($0.id) }
        let matches = windows.filter { window in
            if let id { return window.id == id }
            if let query { return window.app.localizedCaseInsensitiveContains(query) || window.title.localizedCaseInsensitiveContains(query) }
            return false
        }
        let resolved: PetDesktopWindow?
        if displayID != nil { resolved = nil }
        else {
            guard matches.count == 1 else {
                throw IDEToolError.invalidArguments(matches.isEmpty ? "No matching window is available. List desktop targets and retry." : "Ambiguous window. Choose a window_id:\n" + matches.map(\.label).joined(separator: "\n"))
            }
            resolved = matches[0]
        }
        if let displayID, !NSScreen.screens.contains(where: { $0.petDisplayID == displayID }) {
            throw IDEToolError.invalidArguments("The display_id is not connected. List desktop targets and retry.")
        }
        var targetFrame = resolved?.frame ?? displayID.map(CGDisplayBounds) ?? .zero
        guard targetFrame.width > 1, targetFrame.height > 1 else { throw IDEToolError.handlerFailed("The target display is unavailable.") }
        let initialPoint = Self.point(x: x, y: y, frame: targetFrame)
        let appPoint = Self.appKitPoint(initialPoint)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appPoint) }) else {
            throw IDEToolError.handlerFailed("The target display is disconnected or the point falls in a desktop gap.")
        }
        if !authorizationGranted { await requestAccess() }
        authorizationGranted = await driver.authorized(prompt: false)
        guard authorizationGranted else {
            permissionIssue = true
            throw IDEToolError.handlerFailed("No desktop action was performed. Allow this copy of RxCode in System Settings → Privacy & Security → Accessibility, then retry.")
        }
        controller.panelController.show()
        controller.presentation.inputInProgress = true
        defer {
            animation = nil
            controller.presentation.inputInProgress = false
            controller.setWalking(false)
            controller.actionStatusOverlayMessage = nil
        }
        controller.actionStatusOverlayMessage = "Walking to \(resolved?.title.isEmpty == false ? resolved!.title : resolved?.app ?? screen.localizedName)…"
        let travelPoint = action == "scroll" ? Self.nearestEdge(to: initialPoint, frame: targetFrame) : initialPoint
        try await controller.panelController.walk(to: screen, at: Self.appKitPoint(travelPoint))
        try Task.checkCancellation()
        var target = resolved
        if let resolved {
            guard let fresh = await driver.windows().first(where: { $0.id == resolved.id }), fresh.frame == resolved.frame else {
                throw IDEToolError.handlerFailed("The selected window moved or closed while the pet travelled. Retry with a fresh target.")
            }
            animation = "focus"
            controller.actionStatusOverlayMessage = "Raising \(resolved.app) window…"
            target = try await driver.focus(fresh, excluding: controller.panelController.photoWindowIDs)
            targetFrame = target!.frame
            if targetFrame != fresh.frame {
                let restoredPoint = Self.point(x: x, y: y, frame: targetFrame)
                let destination = action == "scroll" ? Self.nearestEdge(to: restoredPoint, frame: targetFrame) : restoredPoint
                guard let restoredScreen = NSScreen.screens.first(where: { $0.frame.contains(Self.appKitPoint(destination)) }) else {
                    throw IDEToolError.handlerFailed("The restored window is not on an available display.")
                }
                controller.actionStatusOverlayMessage = "Walking to restored window…"
                try await controller.panelController.walk(to: restoredScreen, at: Self.appKitPoint(destination))
                animation = "focus"
                try await driver.verifyFocused(target!, excluding: controller.panelController.photoWindowIDs)
            }
        }
        guard NSScreen.screens.contains(where: { $0.petDisplayID == screen.petDisplayID }) else { throw IDEToolError.handlerFailed("The target display disconnected.") }
        if action == "focus" {
            try await Task.sleep(for: .milliseconds(300))
            // Verify again after the action animation; animation alone is never evidence.
            guard let target else { throw IDEToolError.handlerFailed("The target disappeared.") }
            try await driver.verifyFocused(target, excluding: controller.panelController.photoWindowIDs)
            return PetPresentation.result("focused", "Verified that the specifically selected window_id=\(target.id) is restored, raised and focused.")
        }
        let point = Self.point(x: x, y: y, frame: targetFrame)
        if target == nil {
            // A display action resolves the actual window under its point, never a desktop gap.
            target = await driver.windows().first { $0.onScreen && $0.frame.contains(point) && !controller.panelController.photoWindowIDs.contains($0.id) }
        }
        guard let target else { throw IDEToolError.handlerFailed("No actionable window is at the requested position. No input was sent.") }
        animation = action == "click" ? "click" : action == "type" ? "type" : direction
        controller.actionStatusOverlayMessage = action == "click" ? "Clicking…" : action == "type" ? "Typing…" : "Scrolling \(direction)…"
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        // Keep the action sprite visible, but make every pet-owned surface transparent to input.
        let restore = controller.panelController.ignoreInputForAction()
        defer { controller.panelController.restoreInputAfterAction(restore) }
        try await Task.sleep(for: .milliseconds(80))
        do {
            if action == "click" { try await driver.click(target, point: point, excluding: controller.panelController.photoWindowIDs) }
            else if action == "type" { try await driver.typeText(text, into: target, excluding: controller.panelController.photoWindowIDs) }
            else { try await driver.scroll(target, point: point, direction: direction, amount: Int32(rawAmount), excluding: controller.panelController.photoWindowIDs) }
        } catch is CancellationError { throw CancellationError() }
        catch { throw IDEToolError.handlerFailed("\(error.localizedDescription) Typing or scrolling may have delivered earlier input; do not retry blindly.") }
        try await Task.sleep(for: .milliseconds(180))
        return PetPresentation.result("input_dispatched", "Native \(action) input was dispatched to window_id=\(target.id). This confirms input delivery only; inspect the app or capture a fresh screenshot to verify its effect.")
    }

    nonisolated static func fraction(_ value: JSONValue?, fallback: Double?) throws -> Double {
        if value == nil, let fallback { return fallback }
        guard let n = value?.numberValue, n.isFinite, (0...1).contains(n) else {
            throw IDEToolError.invalidArguments("x and y must be finite fractions from 0 to 1, measured from the target's top-left.")
        }
        return n
    }
    nonisolated static func point(x: Double, y: Double, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + min(frame.width - 1, x * frame.width), y: frame.minY + min(frame.height - 1, y * frame.height))
    }
    static func appKitPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y) }
    nonisolated static func nearestEdge(to point: CGPoint, frame: CGRect) -> CGPoint {
        [CGPoint(x: frame.minX + 8, y: point.y), CGPoint(x: frame.maxX - 8, y: point.y),
         CGPoint(x: point.x, y: frame.minY + 8), CGPoint(x: point.x, y: frame.maxY - 8)]
            .min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? point
    }
}
