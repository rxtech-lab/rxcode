import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Observation
import RxCodeCore
import ScreenCaptureKit
import os

nonisolated struct ComputerUseNativeWindowTarget: Hashable, Sendable {
    /// Bundle identifier of the app driven by computer use.
    let appID: String
    /// Accessibility window title, when the tool reported one.
    let windowTitle: String?
}

nonisolated extension ComputerUseMonitorWindow {
    var nativeTarget: ComputerUseNativeWindowTarget? {
        guard case .native(let appID) = id else { return nil }
        return ComputerUseNativeWindowTarget(appID: appID, windowTitle: windowTitle)
    }

    static func observed(in item: [String: JSONValue]) -> [Self] {
        // Only the bundled tool can identify native windows for local capture.
        guard item["server"]?.stringValue == "cua_repl",
              item["tool"]?.stringValue == "js",
              item["pluginId"]?.stringValue == "unified-computer-use@openai-bundled",
              item["status"]?.stringValue == "completed",
              let result = item["result"], result["isError"]?.boolValue != true,
              let surface = result["_meta"]?["codex/toolSurface"] else { return [] }

        switch surface["kind"]?.stringValue {
        case "computerUse":
            guard let app = surface["app"], app["kind"]?.stringValue == "appId",
                  let appID = app["appId"]?.stringValue, !appID.isEmpty else { return [] }
            return [nativeWindow(appID: appID, content: result["content"]?.arrayValue ?? [])]
        case "browserUse":
            guard let window = browserWindow(in: surface) else { return [] }
            return [window]
        default:
            return []
        }
    }

    /// The app identifier comes from tool metadata, so every computer-use call
    /// yields a window even when its text is a diff or carries no header.
    private static func nativeWindow(appID: String, content: [JSONValue]) -> Self {
        var texts: [String] = []
        var images: [String] = []
        collect(content, texts: &texts, images: &images, depth: 0)

        let header = texts.lazy.compactMap(accessibilityHeader(in:)).last
        let preview = images.last.flatMap(thumbnail(from:))
        let windowTitle = header?.title
        return Self(
            id: .native(appID: appID),
            title: windowTitle ?? header?.appName ?? appID,
            appName: header?.appName,
            windowTitle: windowTitle,
            preview: preview
        )
    }

    /// Flattens text and image blocks. Some results wrap a whole MCP result as a
    /// JSON string inside a text block, so those are decoded and walked too.
    private static func collect(_ content: [JSONValue], texts: inout [String], images: inout [String], depth: Int) {
        for block in content {
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue else { continue }
                if depth < 3, text.hasPrefix("{\"content\":"),
                   let data = text.data(using: .utf8),
                   let nested = try? JSONDecoder().decode(JSONValue.self, from: data),
                   let nestedContent = nested["content"]?.arrayValue {
                    collect(nestedContent, texts: &texts, images: &images, depth: depth + 1)
                } else {
                    texts.append(text)
                }
            case "image":
                if let data = block["data"]?.stringValue { images.append(data) }
            default:
                continue
            }
        }
    }

    /// Reads the window header from a full, diff, or unchanged accessibility state:
    /// - `Window: "Title", App: Name.`
    /// - `The following is a diff from the previous accessibility tree for Window: "Title" with ~ and + …`
    /// - `There has been no change in the accessibility tree for Window: "Title".`
    /// The header may follow other text (app instructions, a focused-element line).
    static func accessibilityHeader(in text: String) -> (title: String?, appName: String?)? {
        var found: (title: String?, appName: String?)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.contains("Window: \"") {
            if let match = line.firstMatch(of: #/Window: "(.*)", App: (.+)\.\s*$/#) {
                found = (nonEmpty(match.1), nonEmpty(match.2))
            } else if let match = line.firstMatch(of: #/Window: "(.*)" with ~/#) {
                found = (nonEmpty(match.1), nil)
            } else if let match = line.firstMatch(of: #/Window: "(.*)"\.?\s*$/#) {
                found = (nonEmpty(match.1), nil)
            }
        }
        return found
    }

    private static func nonEmpty(_ value: Substring) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func browserWindow(in surface: JSONValue) -> Self? {
        guard let browserID = surface["browserId"]?.stringValue,
              let screenshot = surface["screenshot"],
              let tabID = screenshot["tabId"]?.stringValue,
              let url = screenshot["url"]?.stringValue,
              let comma = url.firstIndex(of: ","),
              ["data:image/jpeg;base64", "data:image/png;base64"].contains(String(url[..<comma])),
              let preview = thumbnail(from: String(url[url.index(after: comma)...])) else { return nil }
        let title = screenshot["pageUrl"]?.stringValue.flatMap { URL(string: $0)?.host() } ?? "Browser Tab"
        return Self(id: .browser(browserID: browserID, tabID: tabID), title: title, preview: preview)
    }

    private static func thumbnail(from base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ComputerUseWindowCapture.maxPreviewSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

nonisolated enum ComputerUseWindowCapture {
    static let maxPreviewSize: CGFloat = 640
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    static var hasAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for Screen Recording access; opens System Settings when macOS
    /// no longer shows the prompt.
    @MainActor static func requestAccess() {
        guard !CGRequestScreenCaptureAccess(),
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        apply(contentRect: filter.contentRect, pixelScale: CGFloat(filter.pointPixelScale), to: configuration)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    static func apply(contentRect rect: CGRect, pixelScale: CGFloat, to configuration: SCStreamConfiguration) {
        let scale = min(pixelScale, maxPreviewSize / max(rect.width, rect.height, 1))
        configuration.width = max(1, Int(rect.width * scale))
        configuration.height = max(1, Int(rect.height * scale))
    }

    /// Converts a complete screen sample into an image, or `nil` for idle and
    /// blank frames.
    static func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return imageContext.createCGImage(image, from: image.extent)
    }

    /// Picks the on-screen window to stream for `target`: the app's only window
    /// with the reported title, otherwise its frontmost normal window.
    static func resolveWindow(for target: ComputerUseNativeWindowTarget, in windows: [SCWindow]) -> SCWindow? {
        let appID = target.appID.lowercased()
        let candidates = windows.filter { window in
            guard window.isOnScreen, window.windowLayer == 0,
                  window.frame.width >= 80, window.frame.height >= 60,
                  let app = window.owningApplication else { return false }
            return app.bundleIdentifier.lowercased() == appID
        }
        guard candidates.count > 1 else { return candidates.first }

        if let title = target.windowTitle {
            let titled = candidates.filter { $0.title == title }
            if titled.count == 1 { return titled.first }
        }
        return frontmost(of: candidates)
    }

    private static func frontmost(of windows: [SCWindow]) -> SCWindow? {
        // CGWindowList returns on-screen windows ordered front to back.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? CGWindowID { order[number] = index }
        }
        return windows.min { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
    }
}

/// Streams one computer-use app window live with ScreenCaptureKit while the
/// owning view's task runs.
@MainActor
@Observable
final class ComputerUseLiveWindowStream: NSObject, SCStreamDelegate, SCStreamOutput {
    enum Status: Equatable {
        case idle
        case needsAccess
        case searching
        case live
    }

    private(set) var frame: CGImage?
    private(set) var status: Status = .idle
    /// Updated in place as the agent reports new window titles; the next
    /// refresh re-resolves the window without restarting the run loop.
    @ObservationIgnored var target: ComputerUseNativeWindowTarget

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var streamedWindowID: CGWindowID?
    @ObservationIgnored private var streamedSize: CGSize = .zero

    private static let outputQueue = DispatchQueue(label: "app.rxlab.flowcy.code.computer-use-stream")
    private static let logger = Logger(subsystem: "app.rxlab.flowcy.code", category: "ComputerUsePreview")
    private static let framesPerSecond: Int32 = 10
    private static let refreshInterval: Duration = .seconds(2)

    init(target: ComputerUseNativeWindowTarget) {
        self.target = target
        super.init()
    }

    /// Keeps the stream pointed at the right window until cancelled; the agent
    /// may raise another window or open a new one between calls.
    func run() async {
        defer { stopStream() }
        while !Task.isCancelled {
            await refresh(target: target)
            do {
                try await Task.sleep(for: Self.refreshInterval)
            } catch {
                return
            }
        }
    }

    private func refresh(target: ComputerUseNativeWindowTarget) async {
        guard ComputerUseWindowCapture.hasAccess else {
            stopStream()
            status = .needsAccess
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            Self.logger.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }

        guard let window = ComputerUseWindowCapture.resolveWindow(for: target, in: content.windows) else {
            // Keep showing the last frame of a window that was just minimized or closed.
            stopStream()
            if frame == nil { status = .searching }
            return
        }

        if window.windowID == streamedWindowID, let stream {
            await resizeIfNeeded(stream, for: window)
        } else {
            await startStream(for: window)
        }
    }

    private func startStream(for window: SCWindow) async {
        stopStream()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = ComputerUseWindowCapture.configuration(for: filter)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.outputQueue)
        } catch {
            Self.logger.error("Couldn’t add stream output: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.stream = stream
        streamedWindowID = window.windowID
        streamedSize = window.frame.size
        if frame == nil { status = .searching }

        do {
            try await stream.startCapture()
        } catch {
            Self.logger.error("Live preview failed to start: \(error.localizedDescription, privacy: .public)")
            if self.stream === stream { stopStream() }
            return
        }

        // The view may have gone away while capture was starting.
        if Task.isCancelled || self.stream !== stream {
            try? await stream.stopCapture()
        }
    }

    private func resizeIfNeeded(_ stream: SCStream, for window: SCWindow) async {
        let size = window.frame.size
        guard abs(size.width - streamedSize.width) > 2 || abs(size.height - streamedSize.height) > 2 else { return }
        streamedSize = size
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = ComputerUseWindowCapture.configuration(for: filter)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.queueDepth = 3
        try? await stream.updateConfiguration(configuration)
    }

    private func stopStream() {
        guard let stream else { return }
        self.stream = nil
        streamedWindowID = nil
        streamedSize = .zero
        Task { try? await stream.stopCapture() }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == streamID else { return }
            // Drop the stream; the next refresh resolves the window again.
            self.stream = nil
            streamedWindowID = nil
            streamedSize = .zero
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = ComputerUseWindowCapture.image(from: sampleBuffer) else { return }
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == streamID else { return }
            self.frame = frame
            status = .live
        }
    }
}

/// One live stream per computer-use app, shared by the floating preview and the
/// all-windows sheet so a window is never captured twice.
@MainActor
@Observable
final class ComputerUseLiveStreams {
    private(set) var streams: [String: ComputerUseLiveWindowStream] = [:]

    func stream(for window: ComputerUseMonitorWindow) -> ComputerUseLiveWindowStream? {
        guard case .native(let appID) = window.id else { return nil }
        return streams[appID]
    }

    /// Creates streams for new apps, retargets existing ones, and drops apps
    /// that are no longer observed.
    func sync(with windows: [ComputerUseMonitorWindow]) {
        var next: [String: ComputerUseLiveWindowStream] = [:]
        for window in windows {
            guard let target = window.nativeTarget else { continue }
            let stream = streams[target.appID] ?? ComputerUseLiveWindowStream(target: target)
            stream.target = target
            next[target.appID] = stream
        }
        if Set(next.keys) != Set(streams.keys) { streams = next }
    }

    /// Runs every stream until cancelled.
    func run() async {
        let active = Array(streams.values)
        await withDiscardingTaskGroup { group in
            for stream in active {
                group.addTask { await stream.run() }
            }
        }
    }
}
