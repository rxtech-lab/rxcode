import AppKit
import RxCodeCore

@MainActor @Observable
final class WorkspaceDesignSession {
    enum Source: Equatable {
        case target(DesignTarget)
        case swift(file: URL, root: URL, index: Int, workspace: String)
        case document(URL)
        var title: String {
            switch self {
            case .target(let target): target.name
            case .swift(let file, _, _, _), .document(let file): file.lastPathComponent
            }
        }
    }

    let browser: WorkspaceBrowser
    let devices = DesignTargetService()
    weak var window: WindowState?
    var revealBrowser: (() -> WorkspaceBrowser)?
    @ObservationIgnored private let inspectorDefaults: WorkspaceDefaults?
    @ObservationIgnored private var inspectorBrowserSession: (id: UUID, browser: WorkspaceBrowser)?
    private(set) var source: Source?
    private(set) var image: NSImage?
    private(set) var loading = false
    var error: String?
    private var loadID = UUID()

    init(window: WindowState? = nil, defaults: WorkspaceDefaults? = nil, browserSheetID: UUID? = nil) {
        self.window = window
        inspectorDefaults = browserSheetID == nil ? defaults : nil
        let sheetKey = browserSheetID.flatMap { defaults?.key("browserSheetSession.\($0.uuidString)") }
        browser = WorkspaceBrowser(sessionKey: sheetKey)
    }

    var inspectorBrowser: WorkspaceBrowser {
        guard let window, let inspectorDefaults else { return browser }
        let layout = window.inspectorLayout
        if let session = inspectorBrowserSession, session.id == layout.browserID { return session.browser }
        func sessionKey(for id: UUID) -> String { inspectorDefaults.key("inspectorBrowserSession.\(id.uuidString)") }
        let browser = WorkspaceBrowser(
            sessionKey: sessionKey(for: layout.browserID),
            previousSessionKeys: layout.previousBrowserIDs.map(sessionKey(for:))
        )
        inspectorBrowserSession = (layout.browserID, browser)
        return browser
    }

    func open(_ source: Source) async {
        let id = UUID()
        loadID = id
        self.source = source
        image = nil
        error = nil
        loading = true
        defer { if loadID == id { loading = false } }
        do {
            let data: Data
            switch source {
            case .target(let target): data = try await devices.capture(target)
            case .swift(let file, let root, let index, let workspace):
                data = try await XcodeDesignPreview.render(file: file, project: root, index: index, workspaceID: workspace)
            case .document: return
            }
            guard loadID == id else { return }
            guard let bitmap = NSBitmapImageRep(data: data), let cgImage = bitmap.cgImage else { throw IDEToolError.handlerFailed("The preview returned an unreadable image.") }
            image = NSImage(cgImage: cgImage, size: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        } catch { if loadID == id { self.error = error.localizedDescription } }
    }

    func reset() {
        loadID = UUID()
        source = nil
        image = nil
        error = nil
        loading = false
    }

    func selection(point: CGPoint, size: CGSize, source: Source, image: NSImage) async throws -> DesignSelection {
        guard size.width > 0, size.height > 0 else { throw IDEToolError.handlerFailed("The preview is empty.") }
        let fraction = CGPoint(x: point.x / size.width, y: point.y / size.height)
        let location = "From top left: \(Int(fraction.x * 100))% across, \(Int(fraction.y * 100))% down. Screenshot \(Int(image.size.width)) × \(Int(image.size.height))."
        let details: String
        switch source {
        case .target(let target):
            let element = try? await devices.inspect(target, at: fraction, pixels: image.size)
            details = "\(target.id)\n\(target.name)\n\(String((element ?? "Selected screenshot region").prefix(2600)))"
        case .swift(let file, _, let index, _): details = "SwiftUI preview #\(index + 1)\n\(file.path)"
        case .document(let file): details = file.path
        }
        return DesignSelection(title: source.title, context: "\(details)\n\(location)", image: image, point: point)
    }
}
