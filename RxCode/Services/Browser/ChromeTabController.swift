import AppKit
import Combine
import Foundation
import ImageIO
import RxCodeCore


// MARK: - Per-Tab CDP Controller

/// Drives a single Chrome tab over CDP: navigation, history, screencast rendering,
/// input forwarding, isolated-world JS inspection, and screenshots.
@MainActor
final class ChromeTabController: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var title: String?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: String?

    var onStateChange: (() -> Void)?
    var onURLCommit: ((URL) -> Void)?
    var onFrame: ((CGImage, CGSize) -> Void)?
    var onPopupURL: ((URL) -> Void)?

    private(set) var latestFrame: CGImage?
    private(set) var latestFrameLogicalSize: CGSize = .zero

    private var targetId: String?
    private var sessionId: String?
    private var attachTask: Task<String, Error>?
    private var browserHandlerID = UUID()
    private var viewportSize: CGSize = CGSize(width: 1024, height: 768)
    private var viewportScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
    private var isScreencastActive = false
    private var isVisible = false
    private var resizeDebounceTask: Task<Void, Never>?
    private var frameDecodeTask: Task<Void, Never>?
    private var isClosed = false
    private var pendingInitialURL: URL?

    init() {
        let handlerID = browserHandlerID
        Task {
            await ChromeBrowserService.shared.registerBrowserHandler(id: handlerID) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleBrowserEvent(event)
                }
            }
        }
    }

    private func notifyChange() {
        objectWillChange.send()
        onStateChange?()
    }

    // MARK: - Session Attachment

    func ensureSession() async throws -> String {
        if isClosed { throw ChromeBrowserError.connectionClosed }
        if let sessionId { return sessionId }
        if let attachTask { return try await attachTask.value }

        let size = viewportSize
        let scale = viewportScale

        let task = Task<String, Error> { [weak self] in
            let (tid, sid) = try await ChromeBrowserService.shared.createTabSession(url: "about:blank")

            await ChromeBrowserService.shared.registerSessionHandler(sessionId: sid) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleEvent(event)
                }
            }

            _ = try await ChromeBrowserService.shared.send(method: "Page.enable", sessionId: sid)
            _ = try await ChromeBrowserService.shared.send(method: "Runtime.enable", sessionId: sid)
            _ = try await ChromeBrowserService.shared.send(method: "Network.enable", sessionId: sid)
            _ = try await ChromeBrowserService.shared.send(
                method: "Emulation.setDeviceMetricsOverride",
                params: [
                    "width": .number(Double(max(Int(size.width.rounded()), 320))),
                    "height": .number(Double(max(Int(size.height.rounded()), 240))),
                    "deviceScaleFactor": .number(Double(max(scale, 1))),
                    "mobile": .bool(false),
                ],
                sessionId: sid
            )

            await MainActor.run {
                self?.targetId = tid
                self?.sessionId = sid
            }
            return sid
        }

        attachTask = task
        do {
            let sid = try await task.value
            attachTask = nil
            if isVisible {
                await startScreencast()
            }
            return sid
        } catch {
            attachTask = nil
            throw error
        }
    }

    // MARK: - Navigation

    func load(_ targetURL: URL) {
        failure = nil
        isLoading = true
        pendingInitialURL = targetURL
        notifyChange()

        Task { [weak self] in
            guard let self else { return }
            do {
                let sid = try await self.ensureSession()
                let response = try await ChromeBrowserService.shared.send(
                    method: "Page.navigate",
                    params: ["url": .string(targetURL.absoluteString)],
                    sessionId: sid
                )
                if let errorText = response["errorText"]?.stringValue, !errorText.isEmpty, errorText != "net::ERR_ABORTED" {
                    self.isLoading = false
                    self.failure = errorText
                    self.notifyChange()
                } else {
                    await self.refreshHistoryAndMetadata()
                }
            } catch {
                self.isLoading = false
                self.failure = error.localizedDescription
                self.notifyChange()
            }
        }
    }

    func reload() {
        failure = nil
        if sessionId == nil, let target = pendingInitialURL ?? url {
            load(target)
            return
        }
        isLoading = true
        notifyChange()
        Task { [weak self] in
            guard let self, let sid = self.sessionId else { return }
            do {
                _ = try await ChromeBrowserService.shared.send(method: "Page.reload", sessionId: sid)
            } catch {
                self.isLoading = false
                self.failure = error.localizedDescription
                self.notifyChange()
            }
        }
    }

    func stopLoading() {
        isLoading = false
        notifyChange()
        Task { [weak self] in
            guard let sid = self?.sessionId else { return }
            _ = try? await ChromeBrowserService.shared.send(method: "Page.stopLoading", sessionId: sid)
        }
    }

    func goBack() {
        navigateHistory(offset: -1)
    }

    func goForward() {
        navigateHistory(offset: 1)
    }

    private func minimumHistoryIndex(in entries: [JSONValue]) -> Int {
        entries.first?["url"]?.stringValue == "about:blank" ? 1 : 0
    }

    private func navigateHistory(offset: Int) {
        Task { [weak self] in
            guard let self, let sid = self.sessionId else { return }
            guard let history = try? await ChromeBrowserService.shared.send(method: "Page.getNavigationHistory", sessionId: sid),
                  let currentIndex = history["currentIndex"]?.numberValue.map(Int.init),
                  let entries = history["entries"]?.arrayValue else { return }
            let minIndex = self.minimumHistoryIndex(in: entries)
            let targetIndex = currentIndex + offset
            guard targetIndex >= minIndex,
                  entries.indices.contains(targetIndex),
                  let entryId = entries[targetIndex]["id"]?.numberValue else { return }
            _ = try? await ChromeBrowserService.shared.send(
                method: "Page.navigateToHistoryEntry",
                params: ["entryId": .number(entryId)],
                sessionId: sid
            )
            await self.refreshHistoryAndMetadata()
        }
    }

    private func refreshHistoryAndMetadata() async {
        guard let sid = sessionId else { return }
        if let history = try? await ChromeBrowserService.shared.send(method: "Page.getNavigationHistory", sessionId: sid),
           let currentIndex = history["currentIndex"]?.numberValue.map(Int.init),
           let entries = history["entries"]?.arrayValue {
            let minIndex = minimumHistoryIndex(in: entries)
            canGoBack = currentIndex > minIndex
            canGoForward = currentIndex + 1 < entries.count
            if entries.indices.contains(currentIndex) {
                let entry = entries[currentIndex]
                if let urlString = entry["url"]?.stringValue, let parsed = URL(string: urlString),
                   WorkspaceBrowser.isWebURL(parsed) {
                    let changed = self.url != parsed
                    self.url = parsed
                    if changed { onURLCommit?(parsed) }
                }
                if let entryTitle = entry["title"]?.stringValue, !entryTitle.isEmpty {
                    self.title = entryTitle
                }
            }
            notifyChange()
        }
    }

    // MARK: - Viewport & Screencast

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        Task { [weak self] in
            guard let self else { return }
            if visible {
                await self.startScreencast()
            } else {
                await self.stopScreencast()
            }
        }
    }

    func updateViewport(size: CGSize, scale: CGFloat) {
        let clamped = CGSize(width: max(floor(size.width), 100), height: max(floor(size.height), 100))
        let resolvedScale = max(scale, 1)
        guard clamped != viewportSize || resolvedScale != viewportScale else { return }
        viewportSize = clamped
        viewportScale = resolvedScale

        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, let sid = self.sessionId else { return }
            _ = try? await ChromeBrowserService.shared.send(
                method: "Emulation.setDeviceMetricsOverride",
                params: [
                    "width": .number(Double(Int(clamped.width))),
                    "height": .number(Double(Int(clamped.height))),
                    "deviceScaleFactor": .number(Double(resolvedScale)),
                    "mobile": .bool(false),
                ],
                sessionId: sid
            )
            if self.isVisible {
                await self.restartScreencast()
            }
        }
    }

    private func startScreencast() async {
        guard let sid = sessionId, !isScreencastActive, !isClosed else { return }
        isScreencastActive = true
        let maxW = Int(max(viewportSize.width * viewportScale, 320))
        let maxH = Int(max(viewportSize.height * viewportScale, 240))
        _ = try? await ChromeBrowserService.shared.send(
            method: "Page.startScreencast",
            params: [
                "format": .string("jpeg"),
                "quality": .number(88),
                "maxWidth": .number(Double(maxW)),
                "maxHeight": .number(Double(maxH)),
                "everyNthFrame": .number(1),
            ],
            sessionId: sid
        )
    }

    private func stopScreencast() async {
        guard let sid = sessionId, isScreencastActive else { return }
        isScreencastActive = false
        _ = try? await ChromeBrowserService.shared.send(method: "Page.stopScreencast", sessionId: sid)
    }

    private func restartScreencast() async {
        await stopScreencast()
        await startScreencast()
    }

    // MARK: - CDP Events

    private func handleBrowserEvent(_ event: CDPEvent) {
        guard event.method == "Target.targetCreated",
              let info = event.params["targetInfo"],
              info["type"]?.stringValue == "page",
              let openerId = info["openerId"]?.stringValue,
              openerId == targetId,
              let newTargetId = info["targetId"]?.stringValue else { return }

        let urlString = info["url"]?.stringValue ?? ""
        Task { [weak self] in
            // Close Chrome's detached popup target and reopen its URL as a RxCode tab.
            await ChromeBrowserService.shared.closeTarget(targetId: newTargetId)
            if let popupURL = URL(string: urlString), WorkspaceBrowser.isWebURL(popupURL) {
                self?.onPopupURL?(popupURL)
            }
        }
    }

    private func handleEvent(_ event: CDPEvent) {
        switch event.method {
        case "Page.screencastFrame":
            guard let sid = sessionId,
                  let dataString = event.params["data"]?.stringValue,
                  let frameSessionId = event.params["sessionId"]?.numberValue else { return }

            // Acknowledge immediately so Chrome keeps streaming smoothly.
            Task {
                _ = try? await ChromeBrowserService.shared.send(
                    method: "Page.screencastFrameAck",
                    params: ["sessionId": .number(frameSessionId)],
                    sessionId: sid
                )
            }

            let metaWidth = event.params["metadata"]?["deviceWidth"]?.numberValue ?? Double(viewportSize.width)
            let metaHeight = event.params["metadata"]?["deviceHeight"]?.numberValue ?? Double(viewportSize.height)
            let logicalSize = CGSize(width: metaWidth, height: metaHeight)

            frameDecodeTask?.cancel()
            frameDecodeTask = Task.detached(priority: .userInteractive) { [weak self] in
                guard let raw = Data(base64Encoded: dataString),
                      let source = CGImageSourceCreateWithData(raw as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
                await MainActor.run { [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.latestFrame = cgImage
                    self.latestFrameLogicalSize = logicalSize
                    self.onFrame?(cgImage, logicalSize)
                }
            }

        case "Page.frameStartedLoading":
            isLoading = true
            failure = nil
            notifyChange()

        case "Page.loadEventFired", "Page.domContentEventFired":
            Task { await refreshHistoryAndMetadata() }

        case "Page.frameStoppedLoading":
            isLoading = false
            notifyChange()
            Task { await refreshHistoryAndMetadata() }

        case "Page.frameNavigated":
            let frame = event.params["frame"]
            guard frame?["parentId"] == nil else { return }
            if let urlString = frame?["url"]?.stringValue, let parsed = URL(string: urlString),
               WorkspaceBrowser.isWebURL(parsed) {
                let changed = self.url != parsed
                self.url = parsed
                if changed { onURLCommit?(parsed) }
                notifyChange()
            }
            Task { await refreshHistoryAndMetadata() }

        case "Page.navigatedWithinDocument":
            if let urlString = event.params["url"]?.stringValue, let parsed = URL(string: urlString),
               WorkspaceBrowser.isWebURL(parsed) {
                let changed = self.url != parsed
                self.url = parsed
                if changed { onURLCommit?(parsed) }
                notifyChange()
            }
            Task { await refreshHistoryAndMetadata() }

        case "Page.javascriptDialogOpening":
            // Dismiss blocking JS alerts so the headless tab never freezes.
            if let sid = sessionId {
                Task {
                    _ = try? await ChromeBrowserService.shared.send(
                        method: "Page.handleJavaScriptDialog",
                        params: ["accept": .bool(true)],
                        sessionId: sid
                    )
                }
            }

        case "RxCode.disconnected":
            sessionId = nil
            targetId = nil
            isScreencastActive = false
            isLoading = false
            failure = String(localized: "Chrome stopped responding.")
            notifyChange()

        default:
            break
        }
    }

    // MARK: - Input Forwarding

    func dispatchMouse(
        type: String,
        point: CGPoint,
        button: String = "none",
        buttons: Int = 0,
        clickCount: Int = 0,
        modifiers: Int = 0,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) {
        guard let sid = sessionId else { return }
        var params: [String: JSONValue] = [
            "type": .string(type),
            "x": .number(Double(point.x)),
            "y": .number(Double(point.y)),
            "modifiers": .number(Double(modifiers)),
            "button": .string(button),
            "buttons": .number(Double(buttons)),
            "clickCount": .number(Double(clickCount)),
        ]
        if type == "mouseWheel" {
            params["deltaX"] = .number(deltaX)
            params["deltaY"] = .number(deltaY)
        }
        Task {
            _ = try? await ChromeBrowserService.shared.send(method: "Input.dispatchMouseEvent", params: params, sessionId: sid)
        }
    }

    func dispatchKey(
        type: String,
        key: String,
        code: String,
        text: String? = nil,
        unmodifiedText: String? = nil,
        windowsVirtualKeyCode: Int,
        modifiers: Int = 0,
        commands: [String]? = nil
    ) {
        guard let sid = sessionId else { return }
        var params: [String: JSONValue] = [
            "type": .string(type),
            "key": .string(key),
            "code": .string(code),
            "windowsVirtualKeyCode": .number(Double(windowsVirtualKeyCode)),
            "nativeVirtualKeyCode": .number(Double(windowsVirtualKeyCode)),
            "modifiers": .number(Double(modifiers)),
        ]
        if let text, !text.isEmpty {
            params["text"] = .string(text)
            params["unmodifiedText"] = .string(unmodifiedText ?? text)
        }
        if let commands, !commands.isEmpty {
            params["commands"] = .array(commands.map(JSONValue.string))
        }
        Task {
            _ = try? await ChromeBrowserService.shared.send(method: "Input.dispatchKeyEvent", params: params, sessionId: sid)
        }
    }

    func insertText(_ text: String) {
        guard let sid = sessionId, !text.isEmpty else { return }
        Task {
            _ = try? await ChromeBrowserService.shared.send(
                method: "Input.insertText",
                params: ["text": .string(text)],
                sessionId: sid
            )
        }
    }

    func copySelectionToPasteboard(cut: Bool = false) {
        guard let sid = sessionId else { return }
        Task {
            let js = """
            (() => {
              const active = document.activeElement;
              if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA') && typeof active.selectionStart === 'number') {
                const text = active.value.slice(active.selectionStart, active.selectionEnd);
                if (\(cut ? "true" : "false") && text.length > 0) {
                  const start = active.selectionStart, end = active.selectionEnd;
                  active.setRangeText('', start, end, 'start');
                  active.dispatchEvent(new Event('input', {bubbles: true}));
                }
                return text;
              }
              const text = window.getSelection()?.toString() || '';
              if (\(cut ? "true" : "false") && text.length > 0) {
                document.execCommand('delete');
              }
              return text;
            })()
            """
            guard let response = try? await ChromeBrowserService.shared.send(
                method: "Runtime.evaluate",
                params: ["expression": .string(js), "returnByValue": .bool(true)],
                sessionId: sid
            ),
                  let text = response["result"]?["value"]?.stringValue,
                  !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: - Isolated JS Evaluation & Screenshots

    func evaluateIsolatedScript(
        body: String,
        arguments: [String: JSONValue]
    ) async throws -> String {
        let sid = try await ensureSession()
        let frameTree = try await ChromeBrowserService.shared.send(method: "Page.getFrameTree", sessionId: sid)
        guard let frameId = frameTree["frameTree"]?["frame"]?["id"]?.stringValue else {
            throw IDEToolError.handlerFailed("The page frame is unavailable.")
        }
        let world = try await ChromeBrowserService.shared.send(
            method: "Page.createIsolatedWorld",
            params: [
                "frameId": .string(frameId),
                "worldName": .string("rxcode-design"),
                "grantUniveralAccess": .bool(true),
            ],
            sessionId: sid
        )
        guard let contextId = world["executionContextId"]?.numberValue else {
            throw IDEToolError.handlerFailed("Could not create isolated script context.")
        }

        let orderedKeys = arguments.keys.sorted()
        let argData = try JSONEncoder().encode(orderedKeys.map { arguments[$0] ?? .null })
        let argJSON = String(decoding: argData, as: UTF8.self)
        let paramNames = orderedKeys.joined(separator: ", ")
        let expression = """
        (async (\(paramNames)) => {
        \(body)
        })(...\(argJSON))
        """

        let evaluated = try await ChromeBrowserService.shared.send(
            method: "Runtime.evaluate",
            params: [
                "expression": .string(expression),
                "contextId": .number(contextId),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(true),
            ],
            sessionId: sid
        )

        if let exception = evaluated["exceptionDetails"] {
            let description = exception["exception"]?["description"]?.stringValue
                ?? exception["text"]?.stringValue
                ?? "Script evaluation failed."
            throw IDEToolError.handlerFailed(description)
        }
        guard let string = evaluated["result"]?["value"]?.stringValue else {
            throw IDEToolError.handlerFailed("The page did not return an element.")
        }
        return string
    }

    func takeSnapshot() async throws -> NSImage? {
        guard let sid = sessionId else { return nil }
        let response = try await ChromeBrowserService.shared.send(
            method: "Page.captureScreenshot",
            params: ["format": .string("png")],
            sessionId: sid
        )
        guard let base64 = response["data"]?.stringValue,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return NSImage(data: data)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        resizeDebounceTask?.cancel()
        frameDecodeTask?.cancel()
        attachTask?.cancel()
        let sid = sessionId
        let tid = targetId
        let handlerID = browserHandlerID
        sessionId = nil
        targetId = nil
        isScreencastActive = false
        Task {
            await ChromeBrowserService.shared.unregisterBrowserHandler(id: handlerID)
            if let sid {
                await ChromeBrowserService.shared.unregisterSessionHandler(sessionId: sid)
            }
            if let tid {
                await ChromeBrowserService.shared.closeTarget(targetId: tid)
            }
        }
    }
}
