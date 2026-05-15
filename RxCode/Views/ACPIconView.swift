import SwiftUI
import AppKit
import CryptoKit

/// Renders an ACP client/agent icon from a remote URL. Falls back to an
/// SF Symbol placeholder when the URL is missing or the image fails to
/// load. Icons are cached on disk under `~/Library/Caches/RxCode/acp-icons/`
/// and in memory via `ACPIconCache`.
///
/// Registry icons are monochrome SVGs designed to be tinted. We mark the
/// loaded `NSImage` as a template so AppKit / SwiftUI render it in the
/// foreground color — white on dark, black on light — and we expose
/// `.foregroundStyle(.primary)` for that effect.
///
/// SVG: `NSImage(data:)` can miss the format hint for raw SVG bytes, so
/// we write the bytes to a disk cache file using the URL's extension
/// (`.svg` / `.png` / etc.) and load via `NSImage(contentsOf:)`, which
/// dispatches by extension reliably.
struct ACPIconView: View {
    let url: String?
    var size: CGFloat = 16

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            await loadIcon()
        }
    }

    private func loadIcon() async {
        guard let url, let parsed = URL(string: url) else {
            image = nil
            return
        }
        if let cached = await ACPIconCache.shared.image(for: parsed) {
            image = cached
            return
        }
        if let onDisk = ACPIconCache.loadFromDisk(parsed) {
            await ACPIconCache.shared.store(onDisk, for: parsed)
            image = onDisk
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: parsed)
            guard let nsImage = ACPIconCache.makeImage(from: data, sourceURL: parsed) else { return }
            await ACPIconCache.shared.store(nsImage, for: parsed)
            image = nsImage
        } catch {
            // Fall back to placeholder; nothing to log noisily about.
        }
    }
}

actor ACPIconCache {
    static let shared = ACPIconCache()
    private var cache: [URL: NSImage] = [:]

    func image(for url: URL) -> NSImage? { cache[url] }

    func store(_ image: NSImage, for url: URL) { cache[url] = image }

    // MARK: - Disk Cache

    /// Stable cache directory inside the app's Caches container.
    private static let diskRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("RxCode/acp-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskPath(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        return diskRoot.appendingPathComponent("\(hex).\(ext)")
    }

    /// Returns a template-marked NSImage for the cached file at the URL's hash, if present.
    nonisolated static func loadFromDisk(_ url: URL) -> NSImage? {
        let path = diskPath(for: url)
        guard FileManager.default.fileExists(atPath: path.path),
              let image = NSImage(contentsOf: path) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Persists raw bytes to disk using `url`'s extension as the format hint,
    /// then loads the result via `NSImage(contentsOf:)`. Marks the image as a
    /// template so it tints to the surrounding foreground color.
    nonisolated static func makeImage(from data: Data, sourceURL: URL) -> NSImage? {
        let path = diskPath(for: sourceURL)
        do {
            try data.write(to: path, options: .atomic)
        } catch {
            // Disk write failure shouldn't block rendering — fall back to in-memory decode.
            if let image = NSImage(data: data) {
                image.isTemplate = true
                return image
            }
            return nil
        }
        guard let image = NSImage(contentsOf: path) else { return nil }
        image.isTemplate = true
        return image
    }
}
