import AppKit
import ImageIO
import Observation
import RxCodeCore
import RxCodeChatKit

struct PetImagePresentation: Identifiable {
    let id = UUID()
    let image: NSImage
    let title: String
    let style: String
}

/// Acknowledgments come from the rendered native surface, not from accepting tool arguments.
@MainActor @Observable
final class PetPresentation {
    private unowned let controller: PetController
    private(set) var images: [PetImagePresentation] = []
    private(set) var expandedID: UUID?
    @ObservationIgnored private var interactions: [UUID: JSONUIInteraction] = [:]

    func expand(_ id: UUID) { expandedID = id }

    func collapse(_ id: UUID) {
        if expandedID == id { expandedID = nil }
    }

    func retainImage(_ item: PetImagePresentation) {
        images.append(item)
        expand(item.id)
    }

    func removeImage(_ id: UUID) {
        collapse(id)
        images.removeAll { $0.id == id }
    }

    func interaction(for dialog: AgentUIDialog) -> JSONUIInteraction {
        if let state = interactions[dialog.id] { return state }
        let state = JSONUIInteraction(spec: dialog.spec)
        interactions[dialog.id] = state
        return state
    }

    func removeDialog(_ id: UUID) {
        collapse(id)
        interactions.removeValue(forKey: id)
    }
    var widget: JSONUISpec?
    var visibleImageID: UUID?
    var visibleDialogID: UUID?
    var visibleWidgetRevision: UUID?
    var widgetRevision = UUID()
    var inputInProgress = false

    init(controller: PetController) { self.controller = controller }

    func waitUntilVisible(_ predicate: () -> Bool) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard controller.configuration.isEnabled, controller.panelController.isVisible else {
                throw IDEToolError.handlerFailed("The desktop pet is not visible. Nothing was presented.")
            }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw IDEToolError.handlerFailed("The surface did not become visible (another pet prompt may be open). Nothing was confirmed as presented.")
    }

    func showImage(_ arguments: JSONValue) async throws -> JSONValue {
        guard controller.configuration.isEnabled else { throw IDEToolError.handlerFailed("Enable the desktop pet first.") }
        let style = arguments["presentation"]?.stringValue ?? "popover"
        guard ["popover", "bubble"].contains(style) else { throw IDEToolError.invalidArguments("presentation must be popover or bubble.") }
        let data: Data
        if let path = arguments["path"]?.stringValue {
            guard path.hasPrefix("/"), arguments["capture_id"] == nil else {
                throw IDEToolError.invalidArguments("Use an absolute local path or capture_id, not both.")
            }
            data = try await Task.detached(priority: .userInitiated) {
                let url = URL(fileURLWithPath: path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let count = size.fileSize, count <= 20_000_000 else {
                    throw IDEToolError.invalidArguments("Choose a regular image file up to 20 MB.")
                }
                return try Data(contentsOf: url)
            }.value
        } else {
            guard arguments["path"] == nil else { throw IDEToolError.invalidArguments("path must be a string.") }
            guard let capture = controller.screenCapture.latestPhoto,
                  arguments["capture_id"] == nil || arguments["capture_id"]?.stringValue == capture.id.uuidString else {
                throw IDEToolError.handlerFailed("No matching successful screenshot is available. Capture a new photo first.")
            }
            data = capture.data
        }
        // Decode a bounded thumbnail off the main actor, including images from large files.
        let decoded = try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2560,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw IDEToolError.invalidArguments("The file is not a supported image.") }
            return image
        }.value
        try Task.checkCancellation()
        let item = PetImagePresentation(image: NSImage(cgImage: decoded, size: .zero), title: arguments["title"]?.stringValue ?? "Image", style: style)
        retainImage(item)
        controller.panelController.updatePanelLayout()
        controller.panelController.show()
        do { try await waitUntilVisible { visibleImageID == item.id } }
        catch { removeImage(item.id); throw error }
        return Self.result("presented", "The image is visibly displayed beside the pet. The user can collapse, reopen, enlarge or explicitly remove it.")
    }

    /// Invalidate pending acknowledgments/rollback so a user close cannot resurrect old content.
    func clearWidget() {
        widgetRevision = UUID()
        visibleWidgetRevision = nil
        widget = nil
        controller.panelController.updatePanelLayout()
    }

    @discardableResult
    func installWidget(_ spec: JSONUISpec) -> UUID {
        let revision = UUID()
        widgetRevision = revision
        widget = spec
        return revision
    }

    func setWidget(_ arguments: JSONValue) async throws -> JSONValue {
        if arguments["operation"]?.stringValue == "clear" {
            clearWidget()
            return Self.result("cleared", "The pet status widget was cleared.")
        }
        let operation = arguments["operation"]?.stringValue ?? "set"
        guard ["set", "update"].contains(operation) else { throw IDEToolError.invalidArguments("operation must be set, update or clear.") }
        let spec: JSONUISpec
        if operation == "update" {
            guard var current = widget, case .object(let patch)? = arguments["elements"] else {
                throw IDEToolError.invalidArguments("update requires an existing widget and an elements object; each entry replaces that element, null removes it.")
            }
            for (id, value) in patch {
                if value == .null { current.elements.removeValue(forKey: id) }
                else {
                    let encoded = try JSONEncoder().encode(value)
                    do { current.elements[id] = try JSONDecoder().decode(JSONUIElement.self, from: encoded) }
                    catch { throw IDEToolError.invalidArguments("Invalid element '\(id)': \(error.localizedDescription)") }
                }
            }
            if let root = arguments["root"]?.stringValue { current.root = root }
            spec = current
        } else {
            guard let parsed = JSONUISpec(json: arguments["spec"]) else {
                throw IDEToolError.invalidArguments("spec must be JSON with root and elements.")
            }
            spec = parsed
        }
        do { try PetWidgetSchema.validate(spec) }
        catch { throw IDEToolError.invalidArguments(error.localizedDescription) }
        guard controller.configuration.isEnabled else { throw IDEToolError.handlerFailed("Enable the desktop pet first.") }
        let previous = widget
        let revision = installWidget(spec)
        controller.panelController.show()
        do { try await waitUntilVisible { visibleWidgetRevision == revision } }
        catch { if widgetRevision == revision { widget = previous }; throw error }
        return Self.result("presented", "The JSON widget is visibly rendered beside the pet. Values are agent-supplied unless explicitly bound to live IDE state.")
    }

    static func result(_ status: String, _ message: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]),
                 "isError": .bool(false), "structuredContent": .object(["status": .string(status), "visible": .bool(status == "presented")])])
    }
}
