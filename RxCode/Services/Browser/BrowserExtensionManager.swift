import AppKit
import RxCodeCore
import WebKit

/// An extension the user added to the workspace browser. Files live in
/// `BrowserExtensions/<id>/`, and the ID doubles as the extension context's
/// unique identifier so `chrome.storage` data survives relaunches.
nonisolated struct InstalledBrowserExtension: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var version: String
    /// Chrome's extension ID when imported from a Chrome profile.
    var chromeID: String?
    var isEnabled = true
    var installedAt = Date()
    /// Optional permissions and sites the user allowed after installation.
    var grantedPermissions: [String] = []
    var grantedMatchPatterns: [String] = []

    init(id: UUID, name: String, version: String, chromeID: String?) {
        self.id = id
        self.name = name
        self.version = version
        self.chromeID = chromeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        chromeID = try container.decodeIfPresent(String.self, forKey: .chromeID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        grantedPermissions = try container.decodeIfPresent([String].self, forKey: .grantedPermissions) ?? []
        grantedMatchPatterns = try container.decodeIfPresent([String].self, forKey: .grantedMatchPatterns) ?? []
    }
}

/// Owns the app-wide `WKWebExtensionController` shared by every workspace browser
/// tab, the list of installed extensions, and the controller delegate that maps
/// extension requests (tabs, windows, popups, permissions) onto workspace browsers.
@MainActor @Observable
final class BrowserExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let shared = BrowserExtensionManager()

    enum Status: Equatable {
        case working(String)
        case finished(String)
        case failed(String)
    }

    @ObservationIgnored let controller: WKWebExtensionController
    private(set) var installed: [InstalledBrowserExtension] = []
    private(set) var contexts: [UUID: WKWebExtensionContext] = [:]
    /// Load failures and manifest warnings, shown in the extension list.
    private(set) var problems: [UUID: String] = [:]
    /// Changes when an extension updates its toolbar icon, badge, or title.
    private(set) var actionRevision = 0
    /// Progress of the latest install, shown as an overlay on the browser.
    var status: Status?

    @ObservationIgnored private var windows: [WeakWindow] = []
    @ObservationIgnored private weak var focusedWindow: BrowserExtensionWindow?
    @ObservationIgnored private var actionAnchors: [UUID: [WeakView]] = [:]
    @ObservationIgnored private var started = false

    private struct WeakWindow { weak var window: BrowserExtensionWindow? }
    private struct WeakView { weak var view: NSView? }

    override init() {
        controller = WKWebExtensionController(configuration: .default())
        super.init()
        controller.delegate = self
    }

    // MARK: Storage

    nonisolated static var storageDirectory: URL {
        AppSupport.bundleScopedURL.appendingPathComponent("BrowserExtensions", isDirectory: true)
    }

    private var indexURL: URL { Self.storageDirectory.appendingPathComponent("extensions.json") }

    func folder(for id: UUID) -> URL {
        Self.storageDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.storageDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(installed).write(to: indexURL, options: .atomic)
        } catch {
            status = .failed(String(localized: "Couldn’t save browser extensions: \(error.localizedDescription)"))
        }
    }

    /// Loads saved extensions once. Called before the first browser tab is created.
    func start() {
        guard !started else { return }
        started = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? decoder.decode([InstalledBrowserExtension].self, from: data) else { return }
        installed = saved
        Task {
            for record in saved where record.isEnabled { await load(record) }
        }
    }

    /// A web view configuration that runs the installed extensions.
    func webViewConfiguration(_ configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebViewConfiguration {
        start()
        if configuration.webExtensionController == nil { configuration.webExtensionController = controller }
        return configuration
    }

    func isExtensionURL(_ url: URL) -> Bool {
        url.scheme == "webkit-extension" && controller.extensionContext(for: url) != nil
    }

    func record(for context: WKWebExtensionContext) -> InstalledBrowserExtension? {
        guard let id = UUID(uuidString: context.uniqueIdentifier) else { return nil }
        return installed.first { $0.id == id }
    }

    // MARK: Loading

    private func load(_ record: InstalledBrowserExtension, extension loaded: WKWebExtension? = nil) async {
        do {
            let webExtension: WKWebExtension
            if let loaded { webExtension = loaded } else { webExtension = try await WKWebExtension(resourceBaseURL: folder(for: record.id)) }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.id.uuidString
            context.inspectionName = record.name
            #if DEBUG
            context.isInspectable = true
            #endif
            // Required permissions were accepted when the extension was added.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            for permission in record.grantedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
            }
            for pattern in record.grantedMatchPatterns {
                if let pattern = try? WKWebExtension.MatchPattern(string: pattern) {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
            }
            try controller.load(context)
            contexts[record.id] = context
            let warnings = webExtension.errors.map(\.localizedDescription)
            problems[record.id] = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        } catch {
            problems[record.id] = error.localizedDescription
        }
    }

    private func unload(_ id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    // MARK: Installing

    private struct Prepared {
        let id: UUID
        let webExtension: WKWebExtension
        let replacing: InstalledBrowserExtension?
    }

    /// Unpacks a folder, `.crx`, or `.zip` into staging storage and validates the manifest.
    private func prepare(_ source: URL, chromeID: String?) async throws -> Prepared {
        let existing = chromeID.flatMap { id in installed.first { $0.chromeID == id } }
        let id = existing?.id ?? UUID()
        let staging = Self.storageDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try BrowserExtensionInstaller.unpack(source, into: staging)
        }.value
        do {
            _ = try await WKWebExtension(resourceBaseURL: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        // Move into place only after the manifest loads, so a failed update keeps the old copy.
        if existing != nil { unload(id) }
        let destination = folder(for: id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        let webExtension = try await WKWebExtension(resourceBaseURL: destination)
        return Prepared(id: id, webExtension: webExtension, replacing: existing)
    }

    private func commit(_ prepared: Prepared, chromeID: String?) async {
        let ext = prepared.webExtension
        var record = prepared.replacing ?? InstalledBrowserExtension(id: prepared.id, name: "", version: "", chromeID: chromeID)
        record.name = ext.displayName ?? ext.displayShortName ?? String(localized: "Extension")
        record.version = ext.displayVersion ?? ext.version ?? ""
        record.isEnabled = true
        if let index = installed.firstIndex(where: { $0.id == record.id }) { installed[index] = record } else { installed.append(record) }
        save()
        await load(record, extension: ext)
    }

    /// Imports extensions from a Chrome profile. Choosing them in the import sheet
    /// accepts the permissions they already have in Chrome.
    func importFromChrome(_ candidates: [ChromeExtensionCandidate]) async {
        start()
        guard !candidates.isEmpty else { return }
        status = .working(String(localized: "Adding \(candidates.count) extensions…"))
        var failures: [String] = []
        var added = 0
        for candidate in candidates {
            do {
                let prepared = try await prepare(candidate.directory, chromeID: candidate.chromeID)
                await commit(prepared, chromeID: candidate.chromeID)
                added += 1
            } catch {
                failures.append("\(candidate.name): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            status = .finished(String(localized: "Added \(added) extensions"))
        } else {
            status = .failed(String(localized: "Added \(added) of \(candidates.count) extensions. \(failures.joined(separator: "\n"))"))
        }
    }

    /// Adds an unpacked folder, `.crx`, or `.zip` after the user reviews its permissions.
    func install(from source: URL) async {
        start()
        status = .working(String(localized: "Adding extension…"))
        do {
            let prepared = try await prepare(source, chromeID: nil)
            status = nil
            guard await confirmInstall(prepared.webExtension) else {
                if prepared.replacing == nil { try? FileManager.default.removeItem(at: folder(for: prepared.id)) }
                return
            }
            await commit(prepared, chromeID: nil)
            status = .finished(String(localized: "Added \(prepared.webExtension.displayName ?? source.lastPathComponent)"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) async {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].isEnabled = enabled
        save()
        if enabled { await load(installed[index]) } else { unload(id); problems[id] = nil }
    }

    /// Removes the extension's files and its stored data.
    func remove(_ id: UUID) async {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let name = installed[index].name
        if let context = contexts[id] {
            let types = WKWebExtensionController.allExtensionDataTypes
            if let record = await controller.dataRecord(ofTypes: types, for: context) {
                await controller.removeData(ofTypes: types, from: [record])
            }
        }
        unload(id)
        installed.remove(at: index)
        problems[id] = nil
        actionAnchors[id] = nil
        save()
        try? FileManager.default.removeItem(at: folder(for: id))
        status = .finished(String(localized: "Removed \(name)"))
    }

    // MARK: Windows and tabs

    func didOpen(_ window: BrowserExtensionWindow) {
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(WeakWindow(window: window))
        controller.didOpenWindow(window)
        focus(window)
    }

    func focus(_ window: BrowserExtensionWindow) {
        guard focusedWindow !== window else { return }
        focusedWindow = window
        controller.didFocusWindow(window)
    }

    private var openWindows: [BrowserExtensionWindow] {
        let open = windows.compactMap(\.window).filter { $0.browser?.tabs.isEmpty == false }
        guard let focusedWindow, open.contains(where: { $0 === focusedWindow }) else { return open }
        return [focusedWindow] + open.filter { $0 !== focusedWindow }
    }

    func didOpen(_ tab: WorkspaceBrowserTab) { controller.didOpenTab(tab) }
    func didClose(_ tab: WorkspaceBrowserTab) { controller.didCloseTab(tab, windowIsClosing: false) }
    func didMove(_ tab: WorkspaceBrowserTab, from index: Int, in window: BrowserExtensionWindow) {
        controller.didMoveTab(tab, from: index, in: window)
    }
    func didActivate(_ tab: WorkspaceBrowserTab, previous: WorkspaceBrowserTab?) {
        controller.didActivateTab(tab, previousActiveTab: previous)
        actionRevision += 1
    }
    func didChange(_ tab: WorkspaceBrowserTab, _ properties: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(properties, for: tab)
        if properties.contains(.URL) { actionRevision += 1 }
    }

    // MARK: Toolbar actions

    /// Remembers a toolbar button so the extension's popup opens beneath it.
    func registerActionAnchor(_ view: NSView, for id: UUID) {
        var anchors = (actionAnchors[id] ?? []).filter { $0.view != nil && $0.view !== view }
        anchors.append(WeakView(view: view))
        actionAnchors[id] = anchors
    }

    private func anchor(for context: WKWebExtensionContext) -> NSView? {
        guard let id = record(for: context)?.id else { return nil }
        let views = (actionAnchors[id] ?? []).compactMap(\.view).filter { $0.window != nil }
        return views.first { $0.window?.isKeyWindow == true } ?? views.first
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        openWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        openWindows.first
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let browser = (configuration.window as? BrowserExtensionWindow)?.browser ?? openWindows.first?.browser else {
            completionHandler(nil, Self.noBrowserError)
            return
        }
        let tab = browser.addTab(url: configuration.url, activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    /// RxCode has one browser per workspace window, so new extension windows open as tabs.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let window = openWindows.first, let browser = window.browser else {
            completionHandler(nil, Self.noBrowserError)
            return
        }
        let urls = configuration.tabURLs.isEmpty ? [nil] : configuration.tabURLs.map(Optional.some)
        for url in urls { browser.addTab(url: url, activate: configuration.shouldBeFocused) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            completionHandler(Self.noBrowserError)
            return
        }
        if let anchor = anchor(for: context) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let webView = (action.associatedTab as? WorkspaceBrowserTab)?.webView ?? openWindows.first?.browser?.selectedTab?.webView,
                  webView.window != nil {
            let corner = CGRect(x: webView.bounds.maxX - 24, y: webView.isFlipped ? 0 : webView.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: corner, of: webView, preferredEdge: webView.isFlipped ? .maxY : .minY)
        } else {
            completionHandler(Self.noBrowserError)
            return
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionRevision += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? String(localized: "An extension")
        let lines = permissions.map(Self.describe).sorted()
        Task {
            let allowed = await confirm(
                title: String(localized: "Allow “\(name)” to use more features?"),
                message: lines.map { "• \($0)" }.joined(separator: "\n"),
                confirmTitle: String(localized: "Allow")
            )
            if allowed, let id = record(for: extensionContext)?.id { remember(permissions: permissions.map(\.rawValue), for: id) }
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? String(localized: "An extension")
        Task {
            let allowed = await confirm(
                title: String(localized: "Allow “\(name)” to access these websites?"),
                message: Self.describe(matchPatterns),
                confirmTitle: String(localized: "Allow")
            )
            if allowed, let id = record(for: extensionContext)?.id { remember(patterns: matchPatterns.map(\.string), for: id) }
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? String(localized: "An extension")
        let hosts = Set(urls.compactMap(\.host)).sorted()
        Task {
            let allowed = await confirm(
                title: String(localized: "Allow “\(name)” to access these websites?"),
                message: hosts.map { "• \($0)" }.joined(separator: "\n"),
                confirmTitle: String(localized: "Allow")
            )
            if allowed, let id = record(for: extensionContext)?.id {
                remember(patterns: hosts.map { "*://\($0)/*" }, for: id)
            }
            completionHandler(allowed ? urls : [], nil)
        }
    }

    private func remember(permissions: [String] = [], patterns: [String] = [], for id: UUID) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].grantedPermissions = Array(Set(installed[index].grantedPermissions + permissions)).sorted()
        installed[index].grantedMatchPatterns = Array(Set(installed[index].grantedMatchPatterns + patterns)).sorted()
        save()
    }

    // MARK: Prompts

    private func confirmInstall(_ webExtension: WKWebExtension) async -> Bool {
        let name = webExtension.displayName ?? String(localized: "this extension")
        var lines = webExtension.allRequestedMatchPatterns.isEmpty ? [] : [Self.describe(webExtension.allRequestedMatchPatterns)]
        lines += webExtension.requestedPermissions.map { "• \(Self.describe($0))" }.sorted()
        let warnings = webExtension.errors.map(\.localizedDescription)
        if !warnings.isEmpty {
            lines.append("")
            lines.append(String(localized: "Some features may not work in RxCode:"))
            lines += warnings.map { "• \($0)" }
        }
        return await confirm(
            title: String(localized: "Add “\(name)”?"),
            message: lines.isEmpty ? String(localized: "This extension doesn’t request any permissions.") : lines.joined(separator: "\n"),
            confirmTitle: String(localized: "Add Extension")
        )
    }

    private func confirm(title: String, message: String, confirmTitle: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    static func describe(_ permission: WKWebExtension.Permission) -> String {
        switch permission {
        case .activeTab: String(localized: "Access the current tab when you use the extension")
        case .alarms: String(localized: "Schedule background tasks")
        case .clipboardWrite: String(localized: "Write to the clipboard")
        case .contextMenus, .menus: String(localized: "Add items to context menus")
        case .cookies: String(localized: "Read and change cookies")
        case .declarativeNetRequest, .declarativeNetRequestWithHostAccess: String(localized: "Block or modify network requests")
        case .declarativeNetRequestFeedback: String(localized: "See which network requests it blocked")
        case .nativeMessaging: String(localized: "Communicate with native apps")
        case .scripting: String(localized: "Run scripts on web pages")
        case .storage, .unlimitedStorage: String(localized: "Store data")
        case .tabs: String(localized: "Read your browser tabs")
        case .webNavigation: String(localized: "Read your browsing activity")
        case .webRequest: String(localized: "Observe network requests")
        default: permission.rawValue
        }
    }

    static func describe(_ patterns: Set<WKWebExtension.MatchPattern>) -> String {
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            return String(localized: "• Read and change your data on all websites")
        }
        let hosts = Set(patterns.compactMap(\.host)).sorted()
        return hosts.isEmpty
            ? patterns.map { "• \($0.string)" }.sorted().joined(separator: "\n")
            : hosts.map { "• " + String(localized: "Read and change your data on \($0)") }.joined(separator: "\n")
    }

    private static var noBrowserError: NSError {
        NSError(domain: WKWebExtension.errorDomain, code: WKWebExtension.Error.unknown.rawValue,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Open the browser in RxCode first.")])
    }
}

/// Presents one workspace browser to extensions as a browser window.
@MainActor
final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var browser: WorkspaceBrowser?

    init(browser: WorkspaceBrowser) {
        self.browser = browser
    }

    private var hostWindow: NSWindow? { browser?.tabs.lazy.compactMap(\.webView.window).first }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { browser?.tabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { browser?.selectedTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = hostWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { hostWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (hostWindow?.screen ?? NSScreen.main)?.frame ?? .zero
    }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        hostWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
