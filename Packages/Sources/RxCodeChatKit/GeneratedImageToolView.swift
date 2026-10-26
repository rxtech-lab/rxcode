import SwiftUI
import ImageIO
import RxCodeCore

/// A generated image stays visible in the conversation after the tool completes.
struct GeneratedImageToolView: View {
    let toolCall: ToolCall
    let isStreaming: Bool
    @State private var image: Image?
    @State private var showsPreview = false

    private var output: [String: JSONValue] {
        guard let result = toolCall.result, let data = result.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    private var path: String? { output["savedPath"]?.stringValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Generated image", systemImage: "photo")
                .font(.headline)
            if let image {
                Button {
                    showsPreview = true
                } label: {
                    image.resizable()
                        .scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview generated image")
            } else if toolCall.result == nil && isStreaming {
                ProgressView("Generating image…")
            } else {
                Text(output["displayError"]?.stringValue
                     ?? (toolCall.isError ? "Image generation failed" : "Image not available"))
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: showsPreview)
        #endif
        .task(id: path) {
            image = nil
            guard let path else { return }
            let thumbnail = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil as CGImage? }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let thumbnail { image = Image(decorative: thumbnail, scale: 1) }
        }
        .sheet(isPresented: $showsPreview) {
            NavigationStack {
                Group {
                    if let image {
                        image.resizable().scaledToFit()
                    } else {
                        ContentUnavailableView("Image not available", systemImage: "photo")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .navigationTitle("Generated image")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showsPreview = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 720, minHeight: 400, idealHeight: 600)
            #endif
        }
    }
}
