import AppKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import VisionKit
import WebKit

/// Captures the displayed page or frame once, so the popover, Live Text, and chat share the same image.
@MainActor @Observable
final class PreviewCapture {
    struct Frame: Identifiable {
        let id = UUID()
        let url: URL
        let image: NSImage?
        var caption: String?
    }

    @ObservationIgnored weak var view: NSView?
    @ObservationIgnored private var task: Task<Void, Never>?
    var commentFrame: Frame?
    private(set) var recognized: (frame: Frame, analysis: ImageAnalysis)?
    private(set) var status: String?
    var error: String?

    func prepare(for url: URL, selectText: Bool) {
        if selectText, recognized != nil { recognized = nil; return }
        guard status == nil else { return }
        status = selectText ? "Finding text…" : "Capturing preview…"
        task = Task {
            defer { if !Task.isCancelled { status = nil } }
            do {
                let frame = await snapshot(for: url)
                try Task.checkCancellation()
                if selectText {
                    guard let image = frame.image else { throw CaptureError.unavailable }
                    let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init(.text))
                    try Task.checkCancellation()
                    guard analysis.hasResults(for: .text) else { throw CaptureError.noText }
                    recognized = (frame, analysis)
                } else {
                    commentFrame = frame
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func reset() {
        task?.cancel()
        status = nil
        commentFrame = nil
        recognized = nil
        error = nil
    }

    func snapshot(for url: URL) async -> Frame {
        if let recognized, recognized.frame.url == url { return recognized.frame }
        let unavailable = Frame(url: url, image: nil, caption: "Image preview unavailable")
        guard let view, !view.visibleRect.isEmpty else { return unavailable }
        if let pdf = view as? PDFView, pdf.document?.allowsCopying != true { return unavailable }
        if let player = view as? WKWebView {
            // The video layer can be composited separately from WebKit's view snapshot.
            let frame = try? await player.callAsyncJavaScript("""
                const video = document.querySelector('video');
                if (!video?.videoWidth || video.readyState < 2) return null;
                const scale = Math.min(1, 1600 / Math.max(video.videoWidth, video.videoHeight));
                const canvas = document.createElement('canvas');
                canvas.width = Math.round(video.videoWidth * scale);
                canvas.height = Math.round(video.videoHeight * scale);
                canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
                return canvas.toDataURL('image/png').split(',')[1];
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
            if let frame, let bytes = Data(base64Encoded: frame), let image = NSImage(data: bytes) { return Frame(url: url, image: image) }
            if let image = try? await player.takeSnapshot(configuration: nil) { return Frame(url: url, image: image) }
        }
        let rect = view.visibleRect
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) {
            view.cacheDisplay(in: rect, to: bitmap)
            if let pixels = bitmap.cgImage, Self.hasVisiblePixels(pixels) {
                return Frame(url: url, image: NSImage(cgImage: pixels, size: rect.size))
            }
        }
        // Out-of-process Quick Look providers may draw nothing into an AppKit bitmap.
        let request = QLThumbnailGenerator.Request(fileAt: url, size: rect.size, scale: view.window?.backingScaleFactor ?? 1,
                                                   representationTypes: .thumbnail)
        guard !Task.isCancelled, let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return unavailable
        }
        return Frame(url: url, image: thumbnail.nsImage, caption: "File thumbnail")
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixel = context.data else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.load(fromByteOffset: 3, as: UInt8.self) > 0
    }

    private enum CaptureError: LocalizedError {
        case unavailable, noText
        var errorDescription: String? {
            switch self {
            case .unavailable: "The preview is unavailable for capture."
            case .noText: "Live Text couldn’t find text in this preview."
            }
        }
    }
}

struct PreviewCommentControls: View {
    let url: URL
    @Bindable var capture: PreviewCapture

    var body: some View {
        HStack(spacing: 6) {
            if ImageAnalyzer.isSupported {
                Button {
                    capture.prepare(for: url, selectText: true)
                } label: {
                    Label(capture.recognized == nil ? "Select Text in Preview" : "Return to Preview",
                          systemImage: "text.viewfinder")
                }
                .foregroundStyle(capture.recognized == nil ? Color.secondary : Color.accentColor)
                .help(capture.recognized == nil ? "Select text in the visible preview using Live Text" : "Return to preview")
            }
            Button { capture.prepare(for: url, selectText: false) } label: {
                Label("Comment on Preview", systemImage: "text.bubble")
            }
            .help("Comment on the visible preview")
            .popover(item: $capture.commentFrame) { frame in
                PreviewCommentPopover(url: frame.url, frame: frame) { capture.commentFrame = nil }
            }
        }
        .labelStyle(.iconOnly)
        .disabled(capture.status != nil)
    }
}

extension View {
    func visualPreviewComments(for url: URL, capture: PreviewCapture) -> some View {
        overlay {
            if let recognized = capture.recognized, let image = recognized.frame.image {
                RecognizedPreview(image: image, analysis: recognized.analysis)
                    .background(.background)
            }
        }
        .clipped()
        .previewSelectionComments(for: url, capture: capture)
        .overlay {
            if let status = capture.status {
                ProgressView(status).padding().background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .alert("Preview Comment", isPresented: Binding(get: { capture.error != nil }, set: { if !$0 { capture.error = nil } })) {
            Button("OK") { capture.error = nil }
        } message: { Text(capture.error ?? "") }
        .onDisappear { capture.reset() }
    }
}

private struct RecognizedPreview: NSViewRepresentable {
    let image: NSImage
    let analysis: ImageAnalysis

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = image
        let overlay = ImageAnalysisOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        overlay.trackingImageView = view
        overlay.preferredInteractionTypes = [.textSelection]
        overlay.analysis = analysis
        overlay.selectableItemsHighlighted = true
        overlay.isSupplementaryInterfaceHidden = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
