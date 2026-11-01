import AppKit
import RxCodeCore
import SwiftUI
import WebKit

/// Plays a local video opened from a chat link — for example one the RxCode
/// Agent generated with a video model. WebKit rather than AVKit: generated
/// clips are WebM, which AVFoundation cannot decode.
struct GeneratedVideoSheet: View {
    let file: PreviewFile
    @Environment(\.dismiss) private var dismiss

    static let playableExtensions: Set<String> = ["webm", "mp4", "m4v", "mov"]

    static func canPlay(path: String) -> Bool {
        playableExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private var url: URL { URL(filePath: file.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    var body: some View {
        NavigationStack {
            Group {
                if exists {
                    VideoWebView(url: url)
                } else {
                    ContentUnavailableView(
                        "Video Not Found", systemImage: "film",
                        description: Text("\(file.name) was moved or deleted.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(file.name)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show in Finder")
                    .disabled(!exists)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 860, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity)
    }
}

private struct VideoWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        load(url, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { load(url, in: view) }
    }

    /// Opening the file itself gives WebKit's media document: native controls,
    /// scaled to fit, with sound.
    private func load(_ url: URL, in view: WKWebView) {
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

private struct GeneratedVideoSheetModifier: ViewModifier {
    @Bindable var windowState: WindowState

    func body(content: Content) -> some View {
        content.sheet(item: $windowState.playingVideo) { file in
            GeneratedVideoSheet(file: file)
        }
    }
}

extension View {
    /// Presents `WindowState.playingVideo`. Attach once per window root.
    func generatedVideoSheet(_ windowState: WindowState) -> some View {
        modifier(GeneratedVideoSheetModifier(windowState: windowState))
    }
}
