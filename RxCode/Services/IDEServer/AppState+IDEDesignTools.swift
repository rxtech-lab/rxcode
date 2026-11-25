import AppKit
import ImageIO
import RxCodeCore
import WebKit

extension AppState {
    func handleDesignTool(_ name: String, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let key = resolveCurrentSessionId(sessionKey)
        let contexts = designSessions.values.filter { $0.window != nil }
        let exact = contexts.filter { context in
            guard let w = context.window else { return false }
            return resolveCurrentSessionId(w.currentSessionId ?? w.newSessionKey) == key
        }
        let project = allSessionSummaries.first { $0.id == key }?.projectId ?? threadStore.fetch(id: key)?.projectId
        let candidates = exact.isEmpty ? contexts.filter { project != nil && $0.window?.selectedProject?.id == project } : exact
        guard candidates.count == 1, let design = candidates.first, let window = design.window else {
            throw IDEToolError.handlerFailed("Open this thread in one workspace window so the tool can target its browser and inspector.")
        }
        if name.hasPrefix("ide__browser_") { return try await browserTool(name, arguments, design) }
        if name == "ide__swiftui_preview" || name == "ide__document_preview" {
            guard let path = window.selectedProject?.path, let relative = arguments["path"]?.stringValue else {
                throw IDEToolError.invalidArguments("Select a project and provide a file path.")
            }
            let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let file = URL(fileURLWithPath: relative, relativeTo: root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/"), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw IDEToolError.invalidArguments("Choose an existing file within the project.")
            }
            window.inspectorMode = .preview
            showRightSidebar = true
            if name == "ide__document_preview" {
                await design.open(.document(file))
                return textResult("Opened \(file.lastPathComponent) in the preview inspector.")
            }
            let index = arguments["preview_index"]?.numberValue ?? 0
            guard (0...999).contains(index), index.rounded() == index else { throw IDEToolError.invalidArguments("Invalid preview index.") }
            let source = WorkspaceDesignSession.Source.swift(file: file, root: root, index: Int(index), workspace: arguments["xcode_tab"]?.stringValue ?? "")
            await design.open(source)
            guard design.source == source, let image = design.image, let data = designPNG(image) else {
                throw IDEToolError.handlerFailed(design.error ?? "The preview selection changed.")
            }
            return try designImageResult(data)
        }
        let isMac = name.hasPrefix("ide__app_")
        if name == "ide__app_list_windows" || name == "ide__simulator_list" {
            guard let platform = isMac ? .macOS : DesignTarget.Platform(rawValue: arguments["platform"]?.stringValue ?? ""),
                  isMac || platform != .macOS else { throw IDEToolError.invalidArguments("Use iOS or Android.") }
            let targets = try await design.devices.targets(platform)
            return .array(targets.map { .object(["target_id": .string($0.id), "name": .string($0.name)]) })
        }
        guard let id = arguments["target_id"]?.stringValue, let prefix = id.split(separator: ":").first,
              let platform = DesignTarget.Platform(rawValue: String(prefix)), isMac == (platform == .macOS),
              let target = try await design.devices.targets(platform).first(where: { $0.id == id }) else {
            throw IDEToolError.invalidArguments("List running targets and use a current target_id.")
        }
        if name.hasSuffix("_type") {
            guard let text = arguments["text"]?.stringValue else { throw IDEToolError.invalidArguments("Provide text.") }
            try await design.devices.type(text, in: target)
            return textResult("Typed in \(target.name).")
        }
        let frame = try await design.devices.capture(target)
        if name.hasSuffix("_screenshot") { return try designImageResult(frame) }
        guard let x = arguments["x"]?.numberValue, let y = arguments["y"]?.numberValue,
              (0..<1).contains(x), (0..<1).contains(y), let bitmap = NSBitmapImageRep(data: frame) else {
            throw IDEToolError.invalidArguments("Use x and y fractions from 0 up to, but excluding, 1.")
        }
        let point = CGPoint(x: x, y: y), pixels = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        if name.hasSuffix("_inspect") { return textResult(try await design.devices.inspect(target, at: point, pixels: pixels)) }
        try await design.devices.tap(target, at: point, pixels: pixels)
        return textResult("Clicked \(target.name).")
    }

    private func browserTool(_ name: String, _ args: JSONValue, _ design: WorkspaceDesignSession) async throws -> JSONValue {
        let browser = design.inspectorBrowser
        func info(_ tab: WorkspaceBrowserTab) -> JSONValue {
            .object(["tab_id": .string(tab.id.uuidString), "title": .string(tab.title),
                     "url": tab.address.map { .string($0.absoluteString) } ?? .null, "selected": .bool(tab.id == browser.selectedID)])
        }
        if name == "ide__browser_open" {
            guard let url = WorkspaceBrowser.webAddress(args["url"]?.stringValue ?? "") else { throw IDEToolError.invalidArguments("Provide a web address.") }
            let tab = browser.addTab(url: url)
            _ = design.revealBrowser?()
            return info(tab)
        }
        browser.restoreSessionIfNeeded()
        if name == "ide__browser_tabs" {
            return .array(browser.tabs.map(info))
        }
        guard let id = args["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let tab = browser.tabs.first(where: { $0.id == id }) else { throw IDEToolError.invalidArguments("List browser tabs and provide a current tab_id.") }
        func reveal() {
            browser.selectedID = id
            _ = design.revealBrowser?()
        }
        switch name {
        case "ide__browser_select_tab": reveal()
        case "ide__browser_close_tab": browser.close(id); return textResult("Closed tab.")
        case "ide__browser_navigate":
            switch args["action"]?.stringValue {
            case "back" where tab.canGoBack: tab.goBack()
            case "forward" where tab.canGoForward: tab.goForward()
            case "reload": tab.reload()
            case "open":
                guard let url = WorkspaceBrowser.webAddress(args["url"]?.stringValue ?? "") else { throw IDEToolError.invalidArguments("Provide a web address.") }
                tab.load(url)
            default: throw IDEToolError.invalidArguments("This navigation action is unavailable.")
            }
        case "ide__browser_inspect": return try await tab.inspectPage("elements")
        case "ide__browser_click", "ide__browser_type":
            guard let selector = args["selector"]?.stringValue, !selector.isEmpty else { throw IDEToolError.invalidArguments("Provide an HTML selector.") }
            if name.hasSuffix("_click") { return try await tab.inspectPage("click", selector: selector) }
            guard let text = args["text"]?.stringValue else { throw IDEToolError.invalidArguments("Provide text.") }
            return try await tab.inspectPage("type", selector: selector, text: text)
        case "ide__browser_screenshot":
            reveal()
            if tab.engine == .webkit {
                for _ in 0..<30 where tab.webView.window == nil || tab.webView.bounds.isEmpty {
                    try await Task.sleep(for: .milliseconds(40))
                }
                guard !tab.webView.bounds.isEmpty else {
                    throw IDEToolError.handlerFailed("The tab has no visible screenshot.")
                }
            }
            guard let snapshot = try await tab.takeSnapshot(), let data = designPNG(snapshot) else {
                throw IDEToolError.handlerFailed("The tab has no visible screenshot.")
            }
            return try designImageResult(data)
        default: throw IDEToolError.unknownTool(name)
        }
        return info(tab)
    }

    private func designImageResult(_ data: Data) throws -> JSONValue {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw IDEToolError.handlerFailed("The screenshot could not be decoded.")
        }
        return .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())])])])
    }
}
