import AppKit
import ImageIO
import Observation
import os
import RxCodeCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One-shot user-requested photos. No stream, timer, or background recording is created.
@MainActor
@Observable
final class PetScreenCapture {
    private unowned let controller: PetController
    private(set) var latestPhoto: (id: UUID, data: Data)?
    private var operation: Task<JSONValue, Error>?
    private var operationGeneration: UUID?
    private var generation = UUID()
    private(set) var permissionGranted: Bool
    private(set) var lastRequestGranted: Bool?
    var permissionIssueMessage: String?
    @ObservationIgnored private let preflight: @Sendable () -> Bool
    @ObservationIgnored private let requestAccess: @Sendable () async -> Bool
    @ObservationIgnored private let loadContent: @MainActor () async throws -> SCShareableContent
    @ObservationIgnored private var permissionRequest: Task<Bool, Never>?

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    var applicationIdentity: String {
        "App: \(Bundle.main.bundleIdentifier ?? "Unknown bundle ID")\nLocation: \(Bundle.main.bundleURL.path)\nProcess: \(ProcessInfo.processInfo.processIdentifier)"
    }

    init(controller: PetController,
         preflight: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestAccess: @escaping @Sendable () async -> Bool = {
             await Task.detached(priority: .userInitiated) { CGRequestScreenCaptureAccess() }.value
         },
         loadContent: @escaping @MainActor () async throws -> SCShareableContent = {
             try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
         }) {
        self.controller = controller
        self.preflight = preflight
        self.requestAccess = requestAccess
        self.loadContent = loadContent
        self.permissionGranted = preflight()
    }

    func refreshPermission() { permissionGranted = preflight() }

    func requestPermission(presentRecovery: Bool = true) async {
        if let permissionRequest {
            lastRequestGranted = await permissionRequest.value
            refreshPermission()
            return
        }
        controller.actionStatusOverlayMessage = "Requesting Screen Recording access…"
        controller.logger.info("Screen capture authorization request started; preflight=\(self.permissionGranted)")
        // A floating, nonactivating pet may be used while another app is active.
        // Bring its owning app forward so a first-use system authorization prompt is visible.
        if !AppSupport.isTestProcess { NSApp.activate(ignoringOtherApps: true) }
        let request = requestAccess
        let task = Task { await request() }
        permissionRequest = task
        lastRequestGranted = await task.value
        permissionRequest = nil
        refreshPermission()
        controller.logger.info("Screen capture authorization request completed; returned=\(self.lastRequestGranted == true), preflight=\(self.permissionGranted)")
        controller.actionStatusOverlayMessage = nil
        if presentRecovery && !permissionGranted && lastRequestGranted != true {
            permissionIssueMessage = permissionRecoveryMessage
        }
    }

    func openPermissionSettings() {
        if !NSWorkspace.shared.open(Self.privacySettingsURL) {
            controller.alertErrorMessage = "Could not open System Settings. Open it manually and choose Privacy & Security → Screen & System Audio Recording."
        }
    }

    var permissionRecoveryMessage: String {
        "No screenshot was captured. Open System Settings → Privacy & Security → Screen & System Audio Recording and enable this copy of RxCode. If already enabled, fully quit and reopen this same app, then retry. A previously denied request may not show another prompt. Another installed or rebuilt copy can have a different permission identity.\n\n\(applicationIdentity)"
    }

    /// A requested capture always invokes native authorization if preflight is false.
    /// Preflight is diagnostic: ScreenCaptureKit's result is the authority for this attempt.
    func contentForCapture() async throws -> SCShareableContent {
        refreshPermission()
        if !permissionGranted { await requestPermission(presentRecovery: false) }
        try Task.checkCancellation()
        do {
            let content = try await loadContent()
            permissionGranted = true
            permissionIssueMessage = nil
            return content
        } catch {
            if Self.isPermissionError(error) {
                permissionGranted = false
                permissionIssueMessage = permissionRecoveryMessage
            }
            throw error
        }
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    private func captureFailure(_ error: Error) -> JSONValue {
        let nsError = error as NSError
        controller.logger.error("Screen capture failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code), preflight=\(self.preflight())")
        let permissionError = Self.isPermissionError(error)
        if permissionError {
            permissionGranted = false
            permissionIssueMessage = permissionRecoveryMessage
        }
        let details = "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
        let message = permissionError ? permissionRecoveryMessage : "Screen capture failed. \(details)"
        return Self.text("\(message)\nNative error: \(details)\nPreflight: \(preflight()); request returned: \(lastRequestGranted.map(String.init) ?? "not requested").\n\(applicationIdentity)", isError: true)
    }

    func cancel() {
        generation = UUID()
        // Dragging also calls this when idle; preserve status owned by voice setup or reports.
        guard operation != nil else { return }
        operation?.cancel()
        controller.isTakingPhoto = false
        controller.setWalking(false)
        controller.actionStatusOverlayMessage = nil
    }

    func cancelAndWait() async {
        let pending = operation
        cancel()
        _ = try? await pending?.value
    }

    func listTargets() async throws -> JSONValue {
        refreshPermission()
        let displays = NSScreen.screens.map { screen in
            "display_id=\(screen.petDisplayID) name=\(screen.localizedName) AppKit_bounds=\(screen.frame) current=\(screen.petDisplayID == controller.panelController.currentDisplayID)"
        }
        guard permissionGranted else {
            return Self.text("Screen Recording preflight has not confirmed access. A requested capture will invoke native authorization and check ScreenCaptureKit. For previously denied access, open System Settings → Privacy & Security → Screen & System Audio Recording.\n\(applicationIdentity)\n" + displays.joined(separator: "\n"))
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return Self.text("Screen Recording access granted. Positions use AppKit coordinates: x increases right, y increases up.\n"
                         + displays.joined(separator: "\n") + "\nWindows:\n"
                         + availableWindows(content).map(Self.windowLabel).joined(separator: "\n"))
    }

    func capture(_ arguments: JSONValue) async throws -> JSONValue {
        let previous = operation
        latestPhoto = nil
        cancel()
        let token = generation
        await controller.desktopActions.cancelAndWait()
        // Finish restoring a previous photo's hidden panel before starting another.
        _ = try? await previous?.value
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let task = Task {
            do {
                return try Self.validatedCaptureResult(await self.performCapture(arguments))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return self.captureFailure(error)
            }
        }
        operation = task
        operationGeneration = token
        return try await withTaskCancellationHandler {
            defer {
                if operationGeneration == token { operation = nil; operationGeneration = nil }
            }
            return try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performCapture(_ arguments: JSONValue) async throws -> JSONValue {
        let token = generation
        defer {
            if generation == token {
                controller.isTakingPhoto = false
                controller.setWalking(false)
                controller.actionStatusOverlayMessage = nil
            }
        }
        let displayID = try Self.identifier(arguments["display_id"])
        let windowID = try Self.identifier(arguments["window_id"])
        let query = arguments["window_query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if arguments["window_query"] != nil && query == nil {
            throw IDEToolError.invalidArguments("window_query must be a string.")
        }
        guard windowID == nil || query == nil else {
            throw IDEToolError.invalidArguments("Choose window_id or window_query, not both.")
        }
        guard displayID == nil || (windowID == nil && query == nil) else {
            throw IDEToolError.invalidArguments("Choose either a display or a window.")
        }
        var content = try await contentForCapture()
        guard controller.configuration.isEnabled else {
            return Self.text("Enable the desktop pet in Pet Settings before requesting a photo.", isError: true)
        }
        controller.panelController.show()
        controller.actionStatusOverlayMessage = "Finding photo target…"
        try Task.checkCancellation()
        let targetWindowID: CGWindowID?
        if let windowID { targetWindowID = windowID }
        else if let query {
            guard !query.isEmpty else { throw IDEToolError.invalidArguments("window_query must not be empty.") }
            let matches = availableWindows(content).filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(query)
            }
            guard matches.count == 1 else {
                return Self.text(matches.isEmpty
                    ? "No visible window matches '\(query)'. Restore a minimized window and retry, or list capture targets."
                    : "Choose a window by window_id:\n" + matches.map(Self.windowLabel).joined(separator: "\n"))
            }
            targetWindowID = matches[0].windowID
        } else { targetWindowID = nil }

        var targetDisplayID = displayID ?? controller.panelController.currentDisplayID
        // Re-resolve after travel: windows can move or disappear while the pet is walking.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let window = targetWindowID.flatMap { id in availableWindows(content).first { $0.windowID == id } }
            if targetWindowID != nil && window == nil {
                return Self.text("The requested window is unavailable, minimized, or no longer visible. Restore it and retry.", isError: true)
            }
            let windowFrame = window.map { Self.appKitRect($0.frame) }
            let screen: NSScreen?
            if let windowFrame {
                screen = NSScreen.screens.max { Self.overlap($0.frame, windowFrame) < Self.overlap($1.frame, windowFrame) }
                targetDisplayID = screen?.petDisplayID
            } else { screen = NSScreen.screens.first { $0.petDisplayID == targetDisplayID } }
            guard let screen, content.displays.contains(where: { $0.displayID == screen.petDisplayID }) else {
                return Self.text("The target display disconnected. List capture targets and choose an available display.", isError: true)
            }
            controller.actionStatusOverlayMessage = "Walking to \(window?.title ?? screen.localizedName)…"
            if windowFrame != nil || controller.panelController.currentDisplayID != targetDisplayID {
                try await controller.panelController.walk(to: screen, above: windowFrame)
            }
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            if let id = targetWindowID {
                guard let refreshed = availableWindows(content).first(where: { $0.windowID == id }) else {
                    return Self.text("The window closed or was minimized before the photo. No screenshot was taken.", isError: true)
                }
                if refreshed.frame != window?.frame {
                    if attempt < 2 { continue }
                    return Self.text("The window is still moving. Retry when it stops.", isError: true)
                }
            }
            guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }),
                  NSScreen.screens.contains(where: { $0.petDisplayID == targetDisplayID }) else {
                return Self.text("The target display disconnected before the photo.", isError: true)
            }
            controller.actionStatusOverlayMessage = "Taking photo…"
            controller.isTakingPhoto = true
            try await Task.sleep(for: .milliseconds(650))
            try Task.checkCancellation()
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            if let id = targetWindowID {
                guard let latest = availableWindows(content).first(where: { $0.windowID == id }) else {
                    return Self.text("The window became unavailable before capture. Restore it and retry.", isError: true)
                }
                if latest.frame != window?.frame {
                    controller.isTakingPhoto = false
                    if attempt < 2 { continue }
                    return Self.text("The window is still moving. Retry when it stops.", isError: true)
                }
            }
            // Hide only pet-owned windows; other RxCode windows remain capturable.
            let hidden = controller.panelController.hideForPhoto()
            defer { controller.panelController.restoreAfterPhoto(hidden) }
            let filter: SCContentFilter
            if let window {
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else {
                let excludedIDs = Set(hidden.map { CGWindowID($0.windowNumber) })
                filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excludedIDs.contains($0.windowID) })
            }
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let rect = filter.contentRect
            let downscale = min(1, 2560 / max(rect.width * scale, rect.height * scale, 1))
            configuration.width = max(1, Int(rect.width * scale * downscale))
            configuration.height = max(1, Int(rect.height * scale * downscale))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            try await Task.sleep(for: .milliseconds(100))
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            let data = try await Self.encode(image)
            try Task.checkCancellation()
            let captureID = UUID()
            latestPhoto = (captureID, data)
            return .object(["structuredContent": .object(["capture_id": .string(captureID.uuidString)]), "content": .array([
                .object(["type": .string("text"), "text": .string("Photo of \(window.map(Self.windowLabel) ?? "display_id=\(display.displayID)"). Inspect the attached image to answer the user's request. This was NOT displayed to the user. To show it, call ide__pet_show_image with capture_id=\(captureID.uuidString).")]),
                .object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(data.base64EncodedString())])
            ])])
        }
        throw CancellationError()
    }

    private func availableWindows(_ content: SCShareableContent) -> [SCWindow] {
        let petIDs = controller.panelController.photoWindowIDs
        return content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 && !petIDs.contains($0.windowID) }
    }

    nonisolated static func identifier(_ value: JSONValue?) throws -> UInt32? {
        guard let value else { return nil }
        guard let number = value.numberValue, number.isFinite, number > 0,
              number <= Double(UInt32.max), number.rounded() == number else {
            throw IDEToolError.invalidArguments("Target IDs must be positive integers from list_capture_targets.")
        }
        return UInt32(number)
    }

    nonisolated static func text(_ text: String, isError: Bool = false) -> JSONValue {
        let failurePrefix = "CAPTURE FAILED — NO IMAGE RETURNED. Do not describe or infer screen contents, including from an earlier photo.\n"
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(isError && !text.hasPrefix(failurePrefix) ? failurePrefix + text : text)])]),
            "isError": .bool(isError),
            "structuredContent": .object(["status": .string(isError ? "failed" : "no_image"), "image_available": .bool(false)])
        ])
    }

    nonisolated static func validatedCaptureResult(_ result: JSONValue) -> JSONValue {
        let blocks = result["content"]?.arrayValue ?? []
        let hasImage = blocks.contains { $0["type"]?.stringValue == "image" && !($0["data"]?.stringValue ?? "").isEmpty }
        guard result["isError"]?.boolValue != true, hasImage else {
            return text(blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"), isError: true)
        }
        var metadata: [String: JSONValue] = ["status": .string("captured"), "image_available": .bool(true), "displayed_to_user": .bool(false)]
        if let id = result["structuredContent"]?["capture_id"] { metadata["capture_id"] = id }
        return .object(["content": .array(blocks), "isError": .bool(false), "structuredContent": .object(metadata)])
    }

    private static func windowLabel(_ window: SCWindow) -> String {
        "window_id=\(window.windowID) app=\(window.owningApplication?.applicationName ?? "Unknown") title=\(window.title ?? "Untitled")"
    }

    static func appKitRect(_ rect: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return appKitRect(rect, primaryTop: primaryTop)
    }

    nonisolated static func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    nonisolated private static func encode(_ image: CGImage) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw IDEToolError.notSupported("Could not encode the screenshot.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw IDEToolError.notSupported("Could not finish encoding the screenshot.") }
            return data as Data
        }.value
    }
}

extension NSScreen {
    var petDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
