import RxCodeCore
import WebKit
import XCTest
@testable import RxCode

@MainActor
final class WorkspaceBrowserTests: XCTestCase {
    func testDesignSelectionAndAgentControlsUseTheSameDOMAndWindow() async throws {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        let design = WorkspaceDesignSession()
        window.currentSessionId = "design-thread"
        design.window = window
        app.designSessions[ObjectIdentifier(window)] = design
        let tab = design.browser.addTab()
        tab.webView.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let url = try XCTUnwrap(URL(string: "https://fixture.example/design"))
        tab.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: """
        <title>Design fixture</title>
        <style>
        input,button{position:absolute;box-sizing:border-box;margin:0}
        input{left:0;top:0;width:180px;height:50px}
        button{left:20px;top:80px;width:90px;height:32px}
        </style>
        <input id="draft" aria-label="Task title"><button id="apply" onclick="this.textContent='Applied'">Apply</button>
        """)
        for _ in 0..<100 where tab.webView.title != "Design fixture" { try await Task.sleep(for: .milliseconds(50)) }
        let selected = try await tab.inspectPage("pick", point: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(selected["selector"], .string("#draft"))
        XCTAssertEqual(selected["label"], .string("Task title"))
        let size = tab.webView.frame.size
        let draftBounds = await tab.designHoverBounds(at: CGPoint(x: 40, y: 30), size: size)
        let applyBounds = await tab.designHoverBounds(at: CGPoint(x: 40, y: 90), size: size)
        let outsideBounds = await tab.designHoverBounds(at: CGPoint(x: -1, y: 90), size: size)
        XCTAssertEqual(draftBounds, CGRect(x: 0, y: 0, width: 180, height: 50))
        XCTAssertEqual(applyBounds, CGRect(x: 20, y: 80, width: 90, height: 32))
        XCTAssertNil(outsideBounds)
        func call(_ name: String, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
            var fields = extra
            fields["tab_id"] = .string(tab.id.uuidString)
            return try await app.ideHandleToolCall(name: name, arguments: .object(fields), sessionKey: "design-thread")
        }
        let elements = try await call("ide__browser_inspect")
        guard case .array(let entries) = elements else { return XCTFail("Missing DOM elements") }
        XCTAssertEqual(entries.count, 2)
        _ = try await call("ide__browser_type", ["selector": .string("#draft"), "text": .string("A refined title")])
        _ = try await call("ide__browser_click", ["selector": .string("#apply")])
        let value = try await tab.webView.evaluateJavaScript("document.querySelector('#draft').value + ' ' + document.querySelector('#apply').textContent")
        XCTAssertEqual(value as? String, "A refined title Applied")
        do {
            _ = try await app.ideHandleToolCall(name: "ide__browser_tabs", arguments: .object([:]), sessionKey: "other-thread")
            XCTFail("An unrelated thread accessed the window.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("workspace window")) }
        let names = Set(IDEToolRegistry.designTools.map(\.name))
        XCTAssertEqual(names.count, IDEToolRegistry.designTools.count)
        for name in ["ide__browser_click", "ide__simulator_tap", "ide__app_screenshot", "ide__swiftui_preview", "ide__document_preview"] {
            XCTAssertTrue(names.contains(name))
            XCTAssertEqual(ToolCall(id: "id", name: "mcp__rxcode-ide__\(name)").displayedToolName, name)
            XCTAssertEqual(ToolCall(id: "id", name: "mcpToolCall", input: ["tool": .string(name)]).displayedToolName, name)
        }
    }

    func testXcodePreviewResponsesAndAndroidElementHitTesting() throws {
        let listing = JSONValue.object(["content": .array([.object(["text": .string("* tabIdentifier: windowtab1, workspacePath: /other/App.xcodeproj\n* tabIdentifier: windowtab2, workspacePath: /work/Atlas/Atlas.xcodeproj")])])])
        XCTAssertEqual(XcodeDesignPreview.matchingWorkspace(in: listing, root: "/work/Atlas"), "windowtab2")
        XCTAssertNil(XcodeDesignPreview.matchingWorkspace(in: listing, root: "/work/At"))
        let workspace = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(UUID()).xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let opened = JSONValue.object(["structuredContent": .object([
            "workspacePath": .string(workspace.path),
            "workspaceIdentifier": .string("workspace-42"),
        ])])
        XCTAssertEqual(XcodeDesignPreview.matchingWorkspace(in: opened, root: "/private" + workspace.path), "workspace-42")
        let bytes = Data([0, 1, 2])
        let image = JSONValue.object(["content": .array([.object(["type": .string("image"), "data": .string(bytes.base64EncodedString())])])])
        XCTAssertEqual(try XcodeDesignPreview.snapshot(in: image), bytes)
        let xml = #"<hierarchy><node class="Layout" bounds="[0,0][300,500]"><node class="Button" resource-id="app:id/save" text="Save" bounds="[20,30][90,65]"/></node></hierarchy>UI hierarchy dumped"#
        XCTAssertTrue(AndroidDesignElement.at(CGPoint(x: 45, y: 48), in: Data(xml.utf8))?.contains("app:id/save") == true)
        XCTAssertNil(AndroidDesignElement.at(CGPoint(x: 800, y: 500), in: Data(xml.utf8)))
    }

    func testAddressEntryAcceptsWebAndLocalDevelopmentURLs() {
        XCTAssertEqual(WorkspaceBrowser.webAddress("example.org/preview?q=2")?.absoluteString, "https://example.org/preview?q=2")
        XCTAssertEqual(WorkspaceBrowser.webAddress(" localhost:3000/page ")?.absoluteString, "http://localhost:3000/page")
        XCTAssertEqual(WorkspaceBrowser.webAddress("[::1]:8080")?.absoluteString, "http://[::1]:8080")
        XCTAssertEqual(WorkspaceBrowser.webAddress("https://localhost:8443")?.scheme, "https")
        for invalid in ["", "two words", "/tmp/preview", "https://", "file:///tmp/test", "rxcode://widget/tasks", "javascript:alert(1)"] {
            XCTAssertNil(WorkspaceBrowser.webAddress(invalid), invalid)
        }
    }

    func testLinkOpeningANewWindowCreatesASeparateLiveTab() async throws {
        let browser = WorkspaceBrowser()
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let first = browser.addTab(configuration: config)
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = first.webView
        defer { host.orderOut(nil) }
        let url = try XCTUnwrap(URL(string: "https://fixture.example/popup"))
        first.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>First</title><a id='next' target='_blank' href='about:blank'>Open preview</a>")
        for _ in 0..<100 where first.webView.title != "First" { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await first.webView.evaluateJavaScript("document.querySelector('#next').click()")
        for _ in 0..<100 where browser.tabs.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
        let second = try XCTUnwrap(browser.selectedTab)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertNotEqual(second.id, first.id)
        browser.close(second.id)
        XCTAssertTrue(browser.selectedTab === first)
        XCTAssertEqual(first.webView.title, "First")
    }

    func testSwitchingAndClosingTabsPreservesTheOtherPage() async throws {
        let browser = WorkspaceBrowser()
        let first = browser.addTab()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://fixture.example/one")))
        first.webView.loadSimulatedRequest(request, responseHTML: "<title>First page</title><input id='draft'>")
        for _ in 0..<100 where first.webView.title != "First page" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(first.webView.title, "First page")
        _ = try await first.webView.evaluateJavaScript("document.getElementById('draft').value = 'preserved'")
        let middle = browser.addTab()
        let last = browser.addTab()
        browser.close(middle.id)
        XCTAssertEqual(browser.selectedID, last.id)
        browser.close(last.id)
        XCTAssertTrue(browser.selectedTab === first)
        let value = try await first.webView.evaluateJavaScript("document.getElementById('draft').value")
        XCTAssertEqual(value as? String, "preserved")
        browser.close(first.id)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertNil(browser.selectedTab?.address)
        XCTAssertNotEqual(browser.selectedID, first.id)
    }

    func testInspectorBrowserRestoresPagesAcrossDestinationAndToolSplits() throws {
        let defaults = WorkspaceDefaults(workspaceID: UUID().uuidString)
        let layoutKey = defaults.key(AppStorageKeys.rightInspectorLayout)
        let window = WindowState()
        window.restoreInspectorLayout(forKey: layoutKey)
        let browserID = window.inspectorLayout.browserID
        let run = try XCTUnwrap(window.inspectorLayout.tools.panes[0].tabs.first { $0.tool == .run })
        window.inspectorLayout.tools.split(run.id, beside: window.inspectorLayout.tools.focusedPaneID, edge: .below)
        let design = WorkspaceDesignSession(window: window, defaults: defaults)
        defer {
            UserDefaults.standard.removeObject(forKey: defaults.key("inspectorBrowserSession.\(browserID.uuidString)"))
            UserDefaults.standard.removeObject(forKey: layoutKey)
        }

        let firstPage = try XCTUnwrap(URL(string: "http://localhost:1/first?query=one#section"))
        let removedPage = try XCTUnwrap(URL(string: "http://localhost:1/removed"))
        let secondPage = try XCTUnwrap(URL(string: "http://localhost:1/second"))
        let browser = design.inspectorBrowser
        browser.addTab(url: firstPage)
        let removed = browser.addTab(url: removedPage, activate: false)
        let blank = browser.addTab(activate: false)
        browser.selectedID = blank.id
        browser.close(removed.id)

        let originalPane = window.inspectorLayout.destinations.focusedPaneID
        window.inspectorLayout.destinations.split(.browser, beside: originalPane, edge: .below)
        window.inspectorTab = .run
        XCTAssertEqual(window.inspectorLayout.destinations.panes.compactMap(\.selectedTab), [.inspector, .browser])
        window.inspectorMode = .changes
        XCTAssertEqual(window.inspectorLayout.destinations.panes.compactMap(\.selectedTab), [.changes, .browser])
        window.inspectorMode = .browser
        XCTAssertTrue(design.inspectorBrowser.selectedTab === blank)

        let reopenedWindow = WindowState()
        reopenedWindow.restoreInspectorLayout(forKey: layoutKey)
        XCTAssertEqual(reopenedWindow.inspectorLayout.destinations, window.inspectorLayout.destinations)
        XCTAssertEqual(reopenedWindow.inspectorLayout.browserID, browserID)
        XCTAssertEqual(reopenedWindow.inspectorLayout.tools.panes.count, 2)
        let restored = WorkspaceDesignSession(window: reopenedWindow, defaults: defaults).inspectorBrowser
        restored.restoreSessionIfNeeded()
        XCTAssertEqual(restored.tabs.map(\.requestedURL), [firstPage, nil])
        XCTAssertEqual(restored.selectedID, restored.tabs.last?.id)

        let openedFromLink = WorkspaceDesignSession(window: reopenedWindow, defaults: defaults).inspectorBrowser
        openedFromLink.open(secondPage)
        XCTAssertEqual(openedFromLink.tabs.map(\.requestedURL), [firstPage, secondPage])
        XCTAssertEqual(openedFromLink.selectedTab?.requestedURL, secondPage)
    }

    func testLegacyInspectorBrowserPanesMergeOnceIntoTheBrowserDestination() throws {
        let defaults = WorkspaceDefaults(workspaceID: UUID().uuidString)
        let layoutKey = defaults.key(AppStorageKeys.rightInspectorLayout)
        let top = UUID()
        let bottom = UUID()
        let first = UUID()
        let second = UUID()
        let legacy = """
            {"focusedPaneID":"\(bottom)","panes":[
            {"id":"\(top)","selectedTabID":"\(first)","tabs":[{"id":"\(first)","mode":"Browser"}]},
            {"id":"\(bottom)","selectedTabID":"\(second)","tabs":[{"id":"\(second)","mode":"Browser"}]}]}
            """
        func sessionKey(_ id: UUID) -> String { defaults.key("inspectorBrowserSession.\(id.uuidString)") }
        UserDefaults.standard.set(Data(legacy.utf8), forKey: layoutKey)
        let firstPage = try XCTUnwrap(URL(string: "http://localhost:1/first"))
        let secondPage = try XCTUnwrap(URL(string: "http://localhost:1/second"))
        WorkspaceBrowser(sessionKey: sessionKey(first)).addTab(url: firstPage)
        WorkspaceBrowser(sessionKey: sessionKey(second)).addTab(url: secondPage)

        let window = WindowState()
        window.restoreInspectorLayout(forKey: layoutKey)
        let merged = WorkspaceDesignSession(window: window, defaults: defaults).inspectorBrowser
        defer {
            for id in [first, second, window.inspectorLayout.browserID] {
                UserDefaults.standard.removeObject(forKey: sessionKey(id))
            }
            UserDefaults.standard.removeObject(forKey: layoutKey)
        }
        merged.restoreSessionIfNeeded()
        XCTAssertEqual(merged.tabs.map(\.requestedURL), [secondPage, firstPage])
        XCTAssertEqual(merged.selectedTab?.requestedURL, secondPage)

        let reopened = WindowState()
        reopened.restoreInspectorLayout(forKey: layoutKey)
        let restored = WorkspaceDesignSession(window: reopened, defaults: defaults).inspectorBrowser
        restored.restoreSessionIfNeeded()
        XCTAssertEqual(restored.tabs.map(\.requestedURL), [secondPage, firstPage])
    }

    func testDetachedBrowserSessionKeepsItsOwnTabsAndRemembersClosingTheLastPage() throws {
        let defaults = WorkspaceDefaults(workspaceID: UUID().uuidString)
        let instanceID = UUID()
        defer { UserDefaults.standard.removeObject(forKey: defaults.key("browserSheetSession.\(instanceID.uuidString)")) }
        let browser = WorkspaceDesignSession(defaults: defaults, browserSheetID: instanceID).browser
        let url = try XCTUnwrap(URL(string: "http://localhost:1/detached"))
        browser.open(url)

        let other = WorkspaceDesignSession(defaults: defaults, browserSheetID: UUID()).browser
        other.restoreSessionIfNeeded()
        XCTAssertTrue(other.tabs.isEmpty)

        let reopened = WorkspaceDesignSession(defaults: defaults, browserSheetID: instanceID).browser
        reopened.restoreSessionIfNeeded()
        let page = try XCTUnwrap(reopened.selectedTab)
        XCTAssertEqual(page.requestedURL, url)
        reopened.close(page.id)

        let afterClose = WorkspaceDesignSession(defaults: defaults, browserSheetID: instanceID).browser
        afterClose.restoreSessionIfNeeded()
        XCTAssertEqual(afterClose.tabs.count, 1)
        XCTAssertNil(try XCTUnwrap(afterClose.selectedTab).requestedURL)
    }

    func testBrowserSessionSavesHistoryNavigationAndANewAddressBeforeItLoads() async throws {
        let suite = "BrowserSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = WorkspaceBrowser(sessionKey: "tabs", defaults: defaults)
        let tab = browser.addTab()
        let initial = try XCTUnwrap(URL(string: "http://localhost:1/initial"))
        let next = try XCTUnwrap(URL(string: "http://localhost:1/next#details"))
        tab.webView.loadSimulatedRequest(URLRequest(url: initial), responseHTML: "<title>Navigation fixture</title>")
        for _ in 0..<100 where tab.webView.title != "Navigation fixture" { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await tab.webView.evaluateJavaScript("history.pushState(null, '', '/next#details')")
        for _ in 0..<100 where tab.restorableAddress != next { try await Task.sleep(for: .milliseconds(50)) }

        let afterNavigation = WorkspaceBrowser(sessionKey: "tabs", defaults: defaults)
        afterNavigation.restoreSessionIfNeeded()
        XCTAssertEqual(afterNavigation.selectedTab?.requestedURL, next)

        let pending = try XCTUnwrap(URL(string: "http://localhost:1/pending"))
        tab.load(pending)
        let afterRequest = WorkspaceBrowser(sessionKey: "tabs", defaults: defaults)
        afterRequest.restoreSessionIfNeeded()
        XCTAssertEqual(afterRequest.selectedTab?.requestedURL, pending)
    }

    // MARK: Browser extensions

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserExtensionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// A minimal Manifest V3 extension whose name comes from `_locales`.
    private func makeFixtureExtension(at folder: URL, version: String = "1.0") throws {
        try writeJSON([
            "manifest_version": 3, "name": "__MSG_appName__", "default_locale": "en", "version": version,
            "action": ["default_title": "Fixture"],
            "content_scripts": [["matches": ["https://fixture.example/*"], "js": ["content.js"]]],
        ], to: folder.appendingPathComponent("manifest.json"))
        try writeJSON(["appName": ["message": "Fixture"]], to: folder.appendingPathComponent("_locales/en/messages.json"))
        try Data("document.documentElement.dataset.fixture = '1'".utf8).write(to: folder.appendingPathComponent("content.js"))
    }

    private func littleEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    func testCRXPayloadSupportsVersion2And3AndRejectsOtherFiles() throws {
        let zip = Data("PK\u{03}\u{04}fixture".utf8)
        let crx3 = Data("Cr24".utf8) + littleEndian(3) + littleEndian(5) + Data(repeating: 7, count: 5) + zip
        XCTAssertEqual(try BrowserExtensionInstaller.zipPayload(ofCRX: crx3), zip)
        let crx2 = Data("Cr24".utf8) + littleEndian(2) + littleEndian(3) + littleEndian(2) + Data(repeating: 1, count: 5) + zip
        XCTAssertEqual(try BrowserExtensionInstaller.zipPayload(ofCRX: crx2), zip)
        let unknownVersion = Data("Cr24".utf8) + littleEndian(4) + littleEndian(0) + zip
        XCTAssertThrowsError(try BrowserExtensionInstaller.zipPayload(ofCRX: unknownVersion))
        let notZip = Data("Cr24".utf8) + littleEndian(3) + littleEndian(1) + Data([0]) + Data("not a zip".utf8)
        XCTAssertThrowsError(try BrowserExtensionInstaller.zipPayload(ofCRX: notZip))
        let truncated = Data("Cr24".utf8) + littleEndian(3) + littleEndian(500) + zip
        XCTAssertThrowsError(try BrowserExtensionInstaller.zipPayload(ofCRX: truncated))
    }

    func testChromeScanFindsTheNewestVersionWithItsLocalizedName() throws {
        let chrome = try temporaryDirectory()
        try writeJSON(["profile": ["info_cache": ["Default": ["name": "Work"]]]], to: chrome.appendingPathComponent("Local State"))
        let id = String(repeating: "a", count: 16) + String(repeating: "p", count: 16)
        let extensions = chrome.appendingPathComponent("Default/Extensions/\(id)", isDirectory: true)
        try makeFixtureExtension(at: extensions.appendingPathComponent("1.9.0_0"), version: "1.9.0")
        try makeFixtureExtension(at: extensions.appendingPathComponent("1.10.0_0"), version: "1.10.0")
        try makeFixtureExtension(at: chrome.appendingPathComponent("Default/Extensions/Temp/1_0"))
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)

        let profiles = try BrowserExtensionInstaller.chromeProfiles(in: chrome)
        XCTAssertEqual(profiles.map(\.name), ["Work"])
        let candidates = BrowserExtensionInstaller.chromeExtensions(in: try XCTUnwrap(profiles.first).directory)
        XCTAssertEqual(candidates.map(\.chromeID), [id])
        XCTAssertEqual(candidates.first?.name, "Fixture")
        XCTAssertEqual(candidates.first?.version, "1.10.0")
        XCTAssertEqual(candidates.first?.manifestVersion, 3)
    }

    func testUnpackingACRXFlattensItsFolderAndLoadsInWebKit() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("wrapped/fixture", isDirectory: true)
        try makeFixtureExtension(at: source)
        try writeJSON(["signed": true], to: source.appendingPathComponent("_metadata/verified_contents.json"))
        let zip = root.appendingPathComponent("fixture.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        let crx = root.appendingPathComponent("fixture.crx")
        try (Data("Cr24".utf8) + littleEndian(3) + littleEndian(2) + Data([8, 9]) + Data(contentsOf: zip)).write(to: crx)

        let destination = root.appendingPathComponent("installed", isDirectory: true)
        XCTAssertEqual(try BrowserExtensionInstaller.unpack(crx, into: destination), destination)
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("_metadata").path))
        let webExtension = try await WKWebExtension(resourceBaseURL: destination)
        XCTAssertEqual(webExtension.displayName, "Fixture")
        XCTAssertTrue(BrowserExtensionActions.hasAction(webExtension))

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BrowserExtensionInstaller.unpack(empty, into: root.appendingPathComponent("bad"))) {
            XCTAssertEqual($0 as? BrowserExtensionInstallError, .missingManifest)
        }
    }

    func testBrowserTabsAreVisibleToLoadedExtensions() async throws {
        let folder = try temporaryDirectory().appendingPathComponent("fixture", isDirectory: true)
        try makeFixtureExtension(at: folder)
        let manager = BrowserExtensionManager.shared
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        XCTAssertFalse(manager.isExtensionURL(context.baseURL))
        try manager.controller.load(context)
        defer { try? manager.controller.unload(context) }
        XCTAssertTrue(manager.isExtensionURL(context.baseURL))

        let browser = WorkspaceBrowser()
        let first = browser.addTab()
        let background = browser.addTab(activate: false)
        XCTAssertTrue(first.webView.configuration.webExtensionController === manager.controller)
        XCTAssertEqual(browser.selectedID, first.id)
        let window = try XCTUnwrap(first.window(for: context) as? BrowserExtensionWindow)
        XCTAssertTrue(window === browser.extensionWindow)
        XCTAssertEqual(window.tabs(for: context).count, 2)
        XCTAssertTrue(window.activeTab(for: context) === first)
        XCTAssertTrue(first.isSelected(for: context))
        XCTAssertFalse(background.isSelected(for: context))

        let page = try XCTUnwrap(URL(string: "https://fixture.example/tab"))
        background.loadURL(page, for: context) { XCTAssertNil($0) }
        background.activate(for: context) { XCTAssertNil($0) }
        XCTAssertTrue(browser.selectedTab === background)
        XCTAssertEqual(background.pendingURL(for: context) ?? background.url(for: context), page)
        background.close(for: context) { XCTAssertNil($0) }
        XCTAssertEqual(window.tabs(for: context).count, 1)
    }

    func testContentScriptsRunInWorkspaceTabs() async throws {
        let folder = try temporaryDirectory().appendingPathComponent("fixture", isDirectory: true)
        try makeFixtureExtension(at: folder)
        let manager = BrowserExtensionManager.shared
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: webExtension)
        for pattern in webExtension.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try manager.controller.load(context)
        defer { try? manager.controller.unload(context) }

        let browser = WorkspaceBrowser()
        let tab = browser.addTab()
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = tab.webView
        defer { host.orderOut(nil) }
        let url = try XCTUnwrap(URL(string: "https://fixture.example/page"))
        tab.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>Page</title>")
        var marker: String?
        for _ in 0..<100 {
            marker = try? await tab.webView.evaluateJavaScript("document.documentElement.dataset.fixture") as? String
            if marker == "1" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(marker, "1")
    }

    func testChromeRuntimeManifestParsingAndVersionComparison() throws {
        let manifest = """
        {
          "channels": {
            "Stable": {
              "version": "158.0.8127.88",
              "downloads": {
                "chrome": [
                  {"platform": "mac-arm64", "url": "https://storage.googleapis.com/cft/158.0.8127.88/mac-arm64/chrome-mac-arm64.zip"},
                  {"platform": "mac-x64", "url": "https://storage.googleapis.com/cft/158.0.8127.88/mac-x64/chrome-mac-x64.zip"}
                ]
              }
            }
          }
        }
        """

        let arm = try ChromeBrowserRuntimeInstaller.parseLatestRelease(from: Data(manifest.utf8), platform: "mac-arm64")
        XCTAssertEqual(arm.version, "158.0.8127.88")
        XCTAssertEqual(arm.downloadURL.absoluteString, "https://storage.googleapis.com/cft/158.0.8127.88/mac-arm64/chrome-mac-arm64.zip")

        let x64 = try ChromeBrowserRuntimeInstaller.parseLatestRelease(from: Data(manifest.utf8), platform: "mac-x64")
        XCTAssertEqual(x64.downloadURL.absoluteString, "https://storage.googleapis.com/cft/158.0.8127.88/mac-x64/chrome-mac-x64.zip")

        XCTAssertThrowsError(try ChromeBrowserRuntimeInstaller.parseLatestRelease(from: Data(manifest.utf8), platform: "linux64")) { error in
            XCTAssertEqual(error as? ChromeBrowserRuntimeInstaller.InstallError, .noAsset)
        }

        XCTAssertTrue(ChromeBrowserRuntimeInstaller.isNewer("158.0.8127.88", than: "158.0.8127.37"))
        XCTAssertTrue(ChromeBrowserRuntimeInstaller.isNewer("159.0.0.1", than: "158.9.9999.99"))
        XCTAssertFalse(ChromeBrowserRuntimeInstaller.isNewer("158.0.8127.88", than: "158.0.8127.88"))
        XCTAssertFalse(ChromeBrowserRuntimeInstaller.isNewer("157.0.8127.99", than: "158.0.8127.1"))
    }

    func testChromeRuntimeLocateAndRemoveManaged() throws {
        let tempRoot = try temporaryDirectory()
        func writeFakeBinary(version: String) throws -> URL {
            let binary = ChromeBrowserRuntimeInstaller.managedRoot(tempRoot)
                .appending(path: "\(version)/chrome-\(ChromeBrowserRuntimeInstaller.platformName)/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            return binary
        }

        XCTAssertNil(ChromeBrowserRuntimeInstaller.locateManaged(appSupport: tempRoot))

        _ = try writeFakeBinary(version: "158.0.8127.37")
        let newest = try writeFakeBinary(version: "158.0.8127.88")

        let located = try XCTUnwrap(ChromeBrowserRuntimeInstaller.locateManaged(appSupport: tempRoot))
        XCTAssertEqual(located.version, "158.0.8127.88")
        XCTAssertEqual(located.source, .managed)
        XCTAssertEqual(located.executablePath, newest.path)

        try ChromeBrowserRuntimeInstaller.removeManaged(appSupport: tempRoot)
        XCTAssertNil(ChromeBrowserRuntimeInstaller.locateManaged(appSupport: tempRoot))
    }

    func testChromeDevToolsURLParsing() {
        let stderr = """
        [0101/000000.123456:WARNING:sandbox.cc(1)] some warning
        DevTools listening on ws://127.0.0.1:54321/devtools/browser/abc-123-def
        """
        XCTAssertEqual(
            ChromeBrowserService.extractDevToolsURL(from: stderr)?.absoluteString,
            "ws://127.0.0.1:54321/devtools/browser/abc-123-def"
        )
        XCTAssertNil(ChromeBrowserService.extractDevToolsURL(from: "no devtools url here"))
    }

    func testBrowserEngineManagerPersistsPreferenceAndFallsBackWhenUnavailable() throws {
        let suiteName = "ChromeBrowserEngineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempRoot = try temporaryDirectory()
        let manager = BrowserEngineManager(defaults: defaults, appSupport: tempRoot)
        XCTAssertEqual(manager.selectedEngine, .webkit)
        XCTAssertEqual(manager.activeEngine, .webkit)

        manager.useSystemChromeFallback = false
        manager.selectedEngine = .chrome
        XCTAssertEqual(manager.selectedEngine, .chrome)
        XCTAssertEqual(manager.activeEngine, .webkit)

        let reloaded = BrowserEngineManager(defaults: defaults, appSupport: tempRoot)
        XCTAssertEqual(reloaded.selectedEngine, .chrome)
        XCTAssertFalse(reloaded.useSystemChromeFallback)
        XCTAssertEqual(reloaded.activeEngine, .webkit)
    }

    func testChromeEngineLiveNavigationInspectionAndSnapshot() async throws {
        guard ChromeBrowserRuntimeInstaller.locate() != nil else {
            throw XCTSkip("No Chrome binary available on this Mac.")
        }

        // Start a minimal single-response local HTTP server on loopback.
        let html = """
        <!doctype html><html><head><title>Chrome Fixture</title></head><body>
        <input id="draft" aria-label="Task title">
        <button id="apply" onclick="this.textContent='Applied'">Apply</button>
        </body></html>
        """
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        defer { Darwin.close(serverFD) }
        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(serverFD, 8), 0)
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFD, $0, &addrLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        let serverTask = Task.detached {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            let bytes = Array(response.utf8)
            for _ in 0..<4 {
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { break }
                var buf = [UInt8](repeating: 0, count: 1024)
                _ = Darwin.read(clientFD, &buf, buf.count)
                _ = bytes.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, $0.count) }
                Darwin.close(clientFD)
            }
        }
        defer {
            serverTask.cancel()
            Task { await ChromeBrowserService.shared.stop() }
        }

        let browser = WorkspaceBrowser(engineOverride: .chrome)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        let tab = browser.addTab(url: url)
        XCTAssertEqual(tab.engine, .chrome)

        for _ in 0..<120 where tab.title != "Chrome Fixture" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(tab.title, "Chrome Fixture")
        XCTAssertEqual(tab.address?.host, "127.0.0.1")

        let elements = try await tab.inspectPage("elements")
        guard case .array(let entries) = elements else { return XCTFail("Missing DOM elements") }
        XCTAssertEqual(entries.count, 2)

        _ = try await tab.inspectPage("type", selector: "#draft", text: "Hello Chrome")
        _ = try await tab.inspectPage("click", selector: "#apply")
        let updated = try await tab.inspectPage("elements")
        guard case .array(let updatedEntries) = updated else { return XCTFail("Missing updated DOM elements") }
        XCTAssertTrue(updatedEntries.contains { $0["label"] == .string("Applied") })

        let snapshot = try await tab.takeSnapshot()
        XCTAssertNotNil(snapshot)
        XCTAssertGreaterThan(snapshot?.size.width ?? 0, 0)

        tab.close()
        await ChromeBrowserService.shared.stop()
    }

}
