import Combine
import SwiftUI
import WebKit

@MainActor @Observable
final class WorkspaceBrowser {
    private struct SavedSession: Codable, Equatable {
        let addresses: [URL?]
        let selectedIndex: Int?
    }

    @ObservationIgnored private let sessionKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let previousSessionKeys: [String]
    @ObservationIgnored private let engineOverride: BrowserEngineKind?
    @ObservationIgnored private var hasRestoredSession = false
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private var lastSavedSession: SavedSession?

    private(set) var tabs: [WorkspaceBrowserTab] = []
    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            if let tab = selectedTab {
                let previous = tabs.first { $0.id == oldValue }
                if tab.engine == .webkit {
                    BrowserExtensionManager.shared.didActivate(tab, previous: previous?.engine == .webkit ? previous : nil)
                    didFocus()
                }
            }
            saveSession()
        }
    }
    var selectedTab: WorkspaceBrowserTab? { tabs.first { $0.id == selectedID } }
    /// How browser extensions see this browser: one window holding its tabs.
    @ObservationIgnored private(set) var extensionWindow: BrowserExtensionWindow!

    var activeEngine: BrowserEngineKind {
        engineOverride ?? BrowserEngineManager.shared.activeEngine
    }

    init(
        sessionKey: String? = nil,
        defaults: UserDefaults = .standard,
        previousSessionKeys: [String] = [],
        engineOverride: BrowserEngineKind? = nil
    ) {
        self.sessionKey = sessionKey
        self.defaults = defaults
        self.previousSessionKeys = previousSessionKeys
        self.engineOverride = engineOverride
        extensionWindow = BrowserExtensionWindow(browser: self)
    }

    func restoreSessionIfNeeded() {
        guard let sessionKey, !hasRestoredSession else { return }
        hasRestoredSession = true
        func load(_ key: String) -> SavedSession? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(SavedSession.self, from: data)
        }
        let saved = load(sessionKey)
        let previous = saved == nil ? previousSessionKeys.compactMap(load).filter { !$0.addresses.isEmpty } : []
        guard let session = saved ?? previous.first.map({ first in
            SavedSession(addresses: previous.flatMap(\.addresses), selectedIndex: first.selectedIndex)
        }) else { return }

        isRestoringSession = true
        defer {
            isRestoringSession = false
            if saved == nil { saveSession() }
        }
        lastSavedSession = saved
        let restoredTabs = session.addresses.map { address in
            let tab = appendTab()
            if let address, Self.isWebURL(address) { tab.load(address) }
            return tab
        }
        if let index = session.selectedIndex, restoredTabs.indices.contains(index) {
            selectedID = restoredTabs[index].id
        } else {
            selectedID = restoredTabs.first?.id
        }
    }

    /// Rebuilds open tabs when the user switches the browser engine in Settings,
    /// preserving each tab's current address and the active tab index.
    func syncEngineIfNeeded() {
        let targetEngine = activeEngine
        guard !tabs.isEmpty, tabs.contains(where: { $0.engine != targetEngine }) else { return }

        let savedAddresses = tabs.map { $0.address ?? $0.restorableAddress }
        let selectedIndex = tabs.firstIndex { $0.id == selectedID } ?? 0

        isRestoringSession = true
        defer {
            isRestoringSession = false
            saveSession()
        }

        let oldTabs = tabs
        tabs.removeAll()
        for old in oldTabs {
            if old.engine == .webkit {
                BrowserExtensionManager.shared.didClose(old)
            }
            old.close()
        }

        let rebuilt = savedAddresses.map { address in
            let tab = appendTab(engine: targetEngine)
            if let address, Self.isWebURL(address) {
                tab.load(address)
            }
            return tab
        }

        if rebuilt.indices.contains(selectedIndex) {
            selectedID = rebuilt[selectedIndex].id
        } else {
            selectedID = rebuilt.first?.id
        }
    }

    fileprivate func saveSession() {
        guard let sessionKey, !isRestoringSession else { return }
        let session = SavedSession(addresses: tabs.map(\.restorableAddress),
                                   selectedIndex: tabs.firstIndex { $0.id == selectedID })
        guard session != lastSavedSession, let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
        lastSavedSession = session
    }

    @discardableResult
    func addTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, activate: Bool = true) -> WorkspaceBrowserTab {
        restoreSessionIfNeeded()
        let engine: BrowserEngineKind = configuration != nil ? .webkit : activeEngine
        let tab = appendTab(configuration: configuration, engine: engine)
        if let url { tab.load(url) }
        if activate || selectedID == nil { selectedID = tab.id }
        saveSession()
        return tab
    }

    private func appendTab(
        configuration: WKWebViewConfiguration? = nil,
        engine: BrowserEngineKind? = nil
    ) -> WorkspaceBrowserTab {
        let resolvedEngine = engine ?? (configuration != nil ? .webkit : activeEngine)
        let tab: WorkspaceBrowserTab
        if resolvedEngine == .chrome {
            tab = WorkspaceBrowserTab(chromeIn: self)
            tabs.append(tab)
        } else {
            let extensions = BrowserExtensionManager.shared
            tab = WorkspaceBrowserTab(
                configuration: extensions.webViewConfiguration(configuration ?? WKWebViewConfiguration()),
                browser: self
            )
            tabs.append(tab)
            if tabs.filter({ $0.engine == .webkit }).count == 1 { extensions.didOpen(extensionWindow) }
            extensions.didOpen(tab)
        }
        return tab
    }

    /// Tells extensions this browser is the one the user is working in.
    func didFocus() {
        guard tabs.contains(where: { $0.engine == .webkit }) else { return }
        BrowserExtensionManager.shared.focus(extensionWindow)
    }

    func open(_ url: URL) {
        restoreSessionIfNeeded()
        if let selectedTab, selectedTab.address == nil {
            selectedTab.load(url)
        } else {
            addTab(url: url)
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if tab.engine == .webkit {
            BrowserExtensionManager.shared.didClose(tab)
        }
        tab.close()
        if tabs.isEmpty {
            addTab()
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        saveSession()
    }

    /// Moves a tab into another tab's slot, or to the end when `target` is nil.
    func move(_ id: UUID, to target: UUID?) {
        guard let from = tabs.moveTab(id, to: target), let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.engine == .webkit {
            BrowserExtensionManager.shared.didMove(tab, from: from, in: extensionWindow)
        }
        saveSession()
    }

    /// Opens a copy of a tab's current address right after it.
    func duplicate(_ id: UUID) {
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        let next = tabs.firstIndex { $0.id == id }.flatMap { tabs.indices.contains($0 + 1) ? tabs[$0 + 1].id : nil }
        let copy = addTab(url: source.address)
        if let next { move(copy.id, to: next) }
    }

    /// Closes every tab except `id`.
    func closeOthers(than id: UUID) {
        for tab in tabs where tab.id != id { close(tab.id) }
        selectedID = id
    }

    enum CookieImportStatus: Equatable {
        case importing
        case imported(Int)
        case failed(String)
    }

    /// Progress of the latest Chrome cookie import, shown as an overlay on the browser.
    var cookieImportStatus: CookieImportStatus?

    /// Copies a Chrome profile's cookies into the active browser engine's cookie store.
    func importChromeCookies(from profile: ChromeProfile, sites: [String]) async {
        cookieImportStatus = .importing
        do {
            let cookies = try await Task.detached(priority: .userInitiated) {
                try ChromeCookieImporter.cookies(from: profile, sites: sites)
            }.value

            var imported = 0
            if activeEngine == .chrome {
                imported = try await ChromeBrowserService.shared.importCookies(cookies)
            } else {
                let store = WKWebsiteDataStore.default().httpCookieStore
                for cookie in cookies {
                    guard let httpCookie = cookie.httpCookie else { continue }
                    await store.setCookie(httpCookie)
                    imported += 1
                }
            }

            cookieImportStatus = .imported(imported)
            if let tab = selectedTab, tab.address != nil { tab.reload() }
        } catch {
            cookieImportStatus = .failed(error.localizedDescription)
        }
    }

    static func webAddress(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("/"), !text.contains("\n") else { return nil }
        var components: URLComponents?
        let entered = URLComponents(string: text)
        if let scheme = entered?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            components = entered
        } else {
            // Foundation treats localhost:3000 as a URL scheme.
            let authority = text.prefix { !"/?#".contains($0) }
            if !authority.hasPrefix("["), let colon = authority.firstIndex(of: ":") {
                let port = authority[authority.index(after: colon)...]
                guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            }
            components = URLComponents(string: "https://" + text)
            if let host = components?.host?.lowercased(),
               host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
                || host.hasPrefix("127.") || host == "0.0.0.0" || host == "[::1]" || host == "::1" {
                components?.scheme = "http"
            }
        }
        guard let url = components?.url, isWebURL(url) else { return nil }
        return url
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty, !host.contains(where: \.isWhitespace) else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased())
    }
}

/// Each tab retains its rendering view (WebKit or Chrome CDP controller),
/// including history, scroll position, and page state.
@MainActor
final class WorkspaceBrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let engine: BrowserEngineKind
    let webView: WKWebView
    let chromeController: ChromeTabController?
    @Published private(set) var requestedURL: URL?
    @Published private(set) var failure: String?
    private(set) var restorableAddress: URL?
    private var navigation: WKNavigation?
    private var observedWebURL: URL?
    private(set) weak var browser: WorkspaceBrowser?
    private var observations: [NSKeyValueObservation] = []

    var isLoading: Bool {
        chromeController?.isLoading ?? webView.isLoading
    }

    var canGoBack: Bool {
        chromeController?.canGoBack ?? webView.canGoBack
    }

    var canGoForward: Bool {
        chromeController?.canGoForward ?? webView.canGoForward
    }

    var address: URL? {
        if let chromeController {
            return failure != nil ? requestedURL : chromeController.url ?? requestedURL
        }
        return failure != nil ? requestedURL : webView.url ?? requestedURL
    }

    var title: String {
        if let chromeController {
            if let title = chromeController.title, !title.isEmpty { return title }
            return address?.host ?? String(localized: "New tab")
        }
        if let title = webView.title, !title.isEmpty { return title }
        return address?.host ?? String(localized: "New tab")
    }

    init(configuration: WKWebViewConfiguration, browser: WorkspaceBrowser) {
        self.engine = .webkit
        self.browser = browser
        self.chromeController = nil
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [observe(\.url, .URL), observe(\.title, .title), observe(\.isLoading, .loading),
                        observe(\.canGoBack), observe(\.canGoForward)]
    }

    init(chromeIn browser: WorkspaceBrowser) {
        self.engine = .chrome
        self.browser = browser
        let controller = ChromeTabController()
        self.chromeController = controller
        self.webView = WKWebView(frame: .zero)
        super.init()
        controller.onStateChange = { [weak self] in
            guard let self else { return }
            self.failure = self.chromeController?.failure
            self.objectWillChange.send()
        }
        controller.onURLCommit = { [weak self] url in
            self?.rememberAddress(url)
        }
        controller.onPopupURL = { [weak self] url in
            self?.browser?.addTab(url: url)
        }
    }

    private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>,
                                _ changes: WKWebExtension.TabChangedProperties = []) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] _, _ in
            guard let tab = self else { return }
            Task { @MainActor in
                tab.objectWillChange.send()
                if changes.contains(.URL) { tab.rememberWebViewAddress() }
                if !changes.isEmpty, tab.browser != nil { BrowserExtensionManager.shared.didChange(tab, changes) }
            }
        }
    }

    func load(_ url: URL) {
        requestedURL = url
        failure = nil
        if let chromeController {
            chromeController.load(url)
            rememberAddress(url)
            return
        }
        observedWebURL = webView.url
        navigation = webView.load(URLRequest(url: url))
        rememberAddress(url)
    }

    private func rememberWebViewAddress() {
        let url = webView.url
        guard url != observedWebURL else { return }
        observedWebURL = url
        if let url, failure == nil { rememberAddress(url) }
    }

    private func rememberAddress(_ url: URL?) {
        let address = url.flatMap { WorkspaceBrowser.isWebURL($0) ? $0 : nil }
        guard restorableAddress != address else { return }
        restorableAddress = address
        browser?.saveSession()
    }

    func reload() {
        if let chromeController {
            if let requestedURL, failure != nil { load(requestedURL) }
            else { chromeController.reload() }
            return
        }
        if let requestedURL, failure != nil { load(requestedURL) }
        else { webView.reload() }
    }

    func stopLoading() {
        if let chromeController {
            chromeController.stopLoading()
        } else {
            webView.stopLoading()
        }
    }

    func goBack() {
        if let chromeController {
            chromeController.goBack()
        } else {
            webView.goBack()
        }
    }

    func goForward() {
        if let chromeController {
            chromeController.goForward()
        } else {
            webView.goForward()
        }
    }

    func takeSnapshot() async throws -> NSImage? {
        if let chromeController {
            return try await chromeController.takeSnapshot()
        }
        return try await webView.takeSnapshot(configuration: nil)
    }

    func close() {
        if let chromeController {
            chromeController.close()
        }
        observations.removeAll()
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.navigation = navigation
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === self.navigation, let url = webView.url else { return }
        observedWebURL = url
        rememberAddress(url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, for: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, for: navigation)
    }

    private func handleFailure(_ error: Error, for navigation: WKNavigation?) {
        let error = error as NSError
        guard navigation === self.navigation, !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        requestedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url ?? requestedURL
        failure = error.localizedDescription
        rememberAddress(requestedURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        requestedURL = webView.url ?? requestedURL
        failure = String(localized: "The page stopped responding.")
        rememberAddress(requestedURL)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if WorkspaceBrowser.isWebURL(url) || url.absoluteString == "about:blank" { return .allow }
        if BrowserExtensionManager.shared.isExtensionURL(url) { return .allow }
        if action.targetFrame?.isMainFrame == false, ["about", "data", "blob"].contains(url.scheme) { return .allow }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url,
              WorkspaceBrowser.isWebURL(url) || url.absoluteString == "about:blank"
                || BrowserExtensionManager.shared.isExtensionURL(url) else { return nil }
        // WebKit completes the original request in this view, preserving POST bodies and window.opener.
        return browser?.addTab(configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) { browser?.close(id) }
}

/// Exposes a workspace tab to browser extensions (`chrome.tabs`, content scripts, actions).
extension WorkspaceBrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser?.extensionWindow }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { engine == .webkit ? webView : nil }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { address }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { isLoading ? requestedURL : nil }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { browser?.selectedID == id }
    func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        webView.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin && engine == .webkit { webView.reloadFromOrigin() } else { reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.selectedID = id
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.close(id)
        completionHandler(nil)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {
        if engine == .chrome {
            Task {
                do {
                    completionHandler(try await takeSnapshot(), nil)
                } catch {
                    completionHandler(nil, error)
                }
            }
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in completionHandler(image, error) }
    }
}
