import CoreGraphics
import Foundation

/// Portable packs supply artist-authored pairs. Older packs get a cached pair
/// once per body frame, using their mouth anchor or the legacy face position.
/// Playback only swaps decoded images; it never draws a mouth over the pet.
nonisolated enum PetSpeechFrames {
    static func mouth(for image: CGImage, spec: PetAnimationManifest.FrameSpec,
                      normalized: PetAnimationManifest.Mouth?) -> PetAnimationManifest.Mouth {
        let width = Double(image.width), height = Double(image.height)
        if let normalized {
            return .init(x: normalized.x * width, y: normalized.y * height,
                         width: normalized.width * width, height: normalized.height * height)
        }
        if let mouth = spec.mouth { return mouth }
        return .init(x: (spec.faceX ?? width * 0.5) - width * 0.055,
                     y: (spec.faceY ?? height * 0.42) + height * 0.075,
                     width: width * 0.11, height: height * 0.025)
    }

    static func bake(_ image: CGImage, mouth: PetAnimationManifest.Mouth, open: Bool, electronic: Bool) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rect = CGRect(x: mouth.x, y: Double(image.height) - mouth.y - mouth.height,
                          width: mouth.width, height: mouth.height)
        // Sample the surrounding face to remove the resting mouth before baking.
        let sampleX = max(0, min(image.width - 1, Int(rect.minX - 2)))
        let sampleY = max(0, min(image.height - 1, Int(rect.midY)))
        if let bytes = context.data?.assumingMemoryBound(to: UInt8.self) {
            let offset = sampleY * context.bytesPerRow + sampleX * 4
            let alpha = CGFloat(bytes[offset + 3]) / 255
            let divisor = max(1, CGFloat(bytes[offset + 3]))
            let color = CGColor(red: CGFloat(bytes[offset]) / divisor,
                green: CGFloat(bytes[offset + 1]) / divisor, blue: CGFloat(bytes[offset + 2]) / divisor, alpha: alpha)
            context.setFillColor(color)
            context.fill(rect.insetBy(dx: -1, dy: -1))
        }
        let opening = CGRect(x: rect.minX, y: rect.midY - (open ? rect.width * 0.34 : 1),
                             width: rect.width, height: open ? rect.width * 0.68 : max(2, rect.height * 0.45))
        context.setFillColor(electronic
            ? CGColor(red: 0.16, green: 0.94, blue: 1, alpha: 1)
            : CGColor(red: 0.16, green: 0.07, blue: 0.09, alpha: 1))
        context.fillEllipse(in: opening)
        if open {
            context.setFillColor(electronic
                ? CGColor(red: 0.025, green: 0.09, blue: 0.14, alpha: 1)
                : CGColor(red: 0.95, green: 0.40, blue: 0.54, alpha: 1))
            context.fillEllipse(in: electronic ? opening.insetBy(dx: 1, dy: 1)
                : CGRect(x: opening.minX + opening.width * 0.22, y: opening.minY,
                         width: opening.width * 0.56, height: opening.height * 0.35))
        }
        return context.makeImage() ?? image
    }
}
