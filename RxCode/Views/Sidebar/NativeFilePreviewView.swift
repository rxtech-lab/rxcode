import SwiftUI
import Quartz
import WebKit
import UniformTypeIdentifiers

struct NativeFilePreviewView: View {
    let fileURL: URL
    let capture: PreviewCapture
    @State private var pdf: PDFDocument?
    @State private var finishedLoadingPDF = false

    private var isPDF: Bool { UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .pdf) == true }

    var body: some View {
        Group {
            if let pdf {
                PDFFilePreview(document: pdf, capture: capture)
            } else if isPDF && !finishedLoadingPDF {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuickLookFilePreview(fileURL: fileURL, capture: capture)
            }
        }
        .visualPreviewComments(for: fileURL, capture: capture)
        .task(id: fileURL) {
            guard isPDF else { return }
            let document = await Self.openPDF(at: fileURL)
            guard !Task.isCancelled else { return }
            pdf = document
            finishedLoadingPDF = true
        }
    }

    @concurrent nonisolated private static func openPDF(at url: URL) async -> sending PDFDocument? {
        PDFDocument(url: url)
    }
}

/// Quick Look can host PDFs in another process. An owned PDFView exposes the exact selection and page.
private struct PDFFilePreview: NSViewRepresentable {
    let document: PDFDocument
    let capture: PreviewCapture

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        capture.view = view
        view.autoScales = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// Delegates Office, image, audio, video, and installed format support to macOS.
private struct QuickLookFilePreview: NSViewRepresentable {
    let fileURL: URL
    let capture: PreviewCapture

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        capture.view = view
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QLPreviewView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
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
