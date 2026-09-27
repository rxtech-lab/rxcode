import CoreGraphics
import Foundation
import ImageIO
import libwebp

/// Encodes images as WebP with libwebp (ImageIO can decode WebP but not
/// write it).
public enum WebPEncoder {

    /// Decodes any ImageIO-readable image file and re-encodes it as lossy
    /// WebP. Images larger than `maxPixelSize` on their longest side are
    /// scaled down. Returns nil when the file can't be decoded or encoded.
    public static func encode(fileAt url: URL, quality: Float = 80, maxPixelSize: Int = 2048) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return encode(source: source, quality: quality, maxPixelSize: maxPixelSize)
    }

    /// Same as `encode(fileAt:)` for in-memory image data.
    public static func encode(imageData: Data, quality: Float = 80, maxPixelSize: Int = 2048) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return encode(source: source, quality: quality, maxPixelSize: maxPixelSize)
    }

    /// Encodes a decoded image as lossy WebP at `quality` (0–100).
    public static func encode(_ image: CGImage, quality: Float = 80) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16_383, height <= 16_383 else { return nil }

        // Draw into a known RGBA8 layout libwebp can read directly.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&pixels)

        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer in
            WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), min(max(quality, 0), 100), &output)
        }
        guard size > 0, let output else { return nil }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    /// True when `data` starts with a RIFF/WEBP header.
    public static func isWebP(_ data: Data) -> Bool {
        data.count >= 12
            && data.prefix(4) == Data("RIFF".utf8)
            && data.subdata(in: 8..<12) == Data("WEBP".utf8)
    }

    // MARK: - Helpers

    private static func encode(source: CGImageSource, quality: Float, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, quality: quality)
    }

    /// CoreGraphics only draws premultiplied alpha; WebP expects straight
    /// alpha.
    private static func unpremultiply(_ pixels: inout [UInt8]) {
        var index = 0
        while index < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha > 0 && alpha < 255 {
                pixels[index] = UInt8(min(255, Int(pixels[index]) * 255 / alpha))
                pixels[index + 1] = UInt8(min(255, Int(pixels[index + 1]) * 255 / alpha))
                pixels[index + 2] = UInt8(min(255, Int(pixels[index + 2]) * 255 / alpha))
            }
            index += 4
        }
    }
}
