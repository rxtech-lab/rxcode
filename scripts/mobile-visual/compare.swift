import AppKit
import Foundation

// Canonical RGBA pixels avoid PNG compression and color-layout differences.
func pixels(_ path: String) throws -> (Int, Int, [UInt8]) {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "Unreadable screenshot: \(path)", code: 1)
    }
    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return true
    }
    guard ok else { throw NSError(domain: "Cannot decode screenshot", code: 2) }
    return (cg.width, cg.height, bytes)
}

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("Usage: compare baseline.png latest.png diff.png") }
let (width, height, baseline) = try pixels(args[1])
let (latestWidth, latestHeight, latest) = try pixels(args[2])
guard width == latestWidth && height == latestHeight else {
    print("FAIL: Screenshot dimensions changed (\(width)x\(height) → \(latestWidth)x\(latestHeight)).")
    exit(1)
}
var diff = latest
var changed = 0
for offset in stride(from: 0, to: baseline.count, by: 4) {
    let differs = (0..<3).contains { abs(Int(baseline[offset + $0]) - Int(latest[offset + $0])) > 8 }
    if differs { changed += 1 }
    diff[offset] = differs ? 255 : latest[offset] / 4
    diff[offset + 1] = differs ? 0 : latest[offset + 1] / 4
    diff[offset + 2] = differs ? 255 : latest[offset + 2] / 4
    diff[offset + 3] = 255
}
let fraction = Double(changed) / Double(width * height)
print(String(format: "Changed pixels: %.5f%% (limit 0.1%%, channel tolerance 8/255)", fraction * 100))
if fraction > 0.001 {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    diff.withUnsafeBytes { bytes in bitmap.bitmapData!.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!, count: diff.count) }
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    exit(1)
}
