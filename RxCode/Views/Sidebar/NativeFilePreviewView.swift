import SwiftUI
import Quartz
import WebKit

/// Delegates Office, PDF, image, audio, video, and installed format support to macOS.
struct NativeFilePreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = fileURL as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != fileURL {
            view.previewItem = fileURL as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Renders local HTML with sibling assets, without executing document scripts.
struct HTMLFilePreviewView: NSViewRepresentable {
    let fileURL: URL
    let content: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.content != content || context.coordinator.fileURL != fileURL else { return }
        context.coordinator.content = content
        context.coordinator.fileURL = fileURL
        view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var content: String?
        var fileURL: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Keep navigation in the selected document; links can be opened explicitly outside the preview.
            let url = navigationAction.request.url
            let isDocument = url?.isFileURL == true && url?.standardizedFileURL.path == fileURL?.standardizedFileURL.path
            decisionHandler(isDocument ? .allow : .cancel)
        }
    }
}
