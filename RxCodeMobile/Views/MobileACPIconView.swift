import SwiftUI
#if canImport(SDWebImage)
import SDWebImage
#endif

/// Renders an ACP client/agent icon from a remote URL on the iPhone, mirroring
/// the macOS `ACPIconView`.
///
/// Registry icons are monochrome SVGs that use `fill="currentColor"`. iOS's
/// `UIImage` / SwiftUI `AsyncImage` can't decode raw SVG bytes, so we route the
/// load through `SDWebImageManager` with `SDImageSVGCoder` registered (see
/// `AppDelegate`). The decoded glyph is a black silhouette on a transparent
/// background, so we render it as a `.template` image tinted to the foreground
/// color — visible in both light and dark mode, just like the Mac.
///
/// When the SDWebImage package isn't linked, this falls back to the `cpu`
/// SF Symbol so the project still builds and renders.
struct MobileACPIconView: View {
    let url: String?
    var size: CGFloat = 28

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "cpu")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await loadIcon() }
    }

    private func loadIcon() async {
        image = nil
        guard let url, let parsed = URL(string: url) else { return }
        #if canImport(SDWebImage)
        // Rasterize the vector at the on-screen pixel size so it stays crisp;
        // the SVGs declare a tiny 16pt intrinsic size that would otherwise blur.
        let pixels = size * UIScreen.main.scale
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            SDWebImageManager.shared.loadImage(
                with: parsed,
                options: [.retryFailed],
                context: [.imageThumbnailPixelSize: CGSize(width: pixels, height: pixels)],
                progress: nil
            ) { img, _, _, _, _, _ in
                continuation.resume(returning: img)
            }
        }
        guard !Task.isCancelled else { return }
        image = loaded
        #endif
    }
}
