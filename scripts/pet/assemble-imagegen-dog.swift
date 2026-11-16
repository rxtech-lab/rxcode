#!/usr/bin/env swift
import AppKit
import ImageIO

// Assemble image-generated key poses into the existing four-sheet format.
// Only the feathered mouth crop comes from the speaking illustration, keeping
// fur, eyes and body identical when audio switches between speech frames.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let source = root.appendingPathComponent("scripts/pet/artwork/dog-imagegen")
let output = root.appendingPathComponent("output/pet/detailed-dog")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func load(_ name: String) -> CGImage {
    let image = CGImageSourceCreateWithURL(source.appendingPathComponent(name).appendingPathExtension("png") as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(image, 0, nil)!
}
let closed = load("closed"), open = load("open")
precondition(closed.width == open.width && closed.height == open.height)
precondition(closed.width % 6 == 0 && closed.height % 8 == 0)
let sourceCell = closed.width / 6
precondition(sourceCell == closed.height / 8)
let cell = 256
func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func save(_ image: CGImage, _ name: String) {
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
var keys: [[CGImage]] = [[], []]
for row in 0..<8 {
    for column in 0..<6 {
        let crop = CGRect(x: column * sourceCell, y: row * sourceCell, width: sourceCell, height: sourceCell)
        let body = closed.cropping(to: crop)!
        let speaking = open.cropping(to: crop)!
        let pair = context(sourceCell, sourceCell)
        pair.draw(body, in: CGRect(x: 0, y: 0, width: sourceCell, height: sourceCell))
        // Coordinates are local to the generated 181 px key-pose cells.
        let mouth = CGRect(x: 73, y: sourceCell - 101, width: 38, height: 29)
        let patch = speaking.cropping(to: CGRect(x: mouth.minX, y: 72, width: mouth.width, height: mouth.height))!
        let feather = context(38, 29)
        feather.draw(patch, in: CGRect(x: 0, y: 0, width: 38, height: 29))
        let bytes = feather.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<29 {
            for x in 0..<38 {
                let distance = min(x, 37 - x, y, 28 - y)
                let opacity = min(1, Double(distance) / 5)
                for channel in 0..<4 {
                    let index = y * feather.bytesPerRow + x * 4 + channel
                    bytes[index] = UInt8(Double(bytes[index]) * opacity)
                }
            }
        }
        pair.draw(feather.makeImage()!, in: mouth)
        keys[0].append(body)
        keys[1].append(pair.makeImage()!)
    }
}
for page in 0..<4 {
    var metadata: [[String: Any]] = []
    for variant in 0..<2 {
        let atlas = context(cell * 6, cell * 8)
        for row in 0..<8 {
            for column in 0..<6 {
                let index = page * 6 + column
                let phase = Double(index) / 24 * 2 * Double.pi
                let key = index / 4
                let breath = sin(phase) * (row == 3 ? 0.008 : 0.014)
                let hop = row == 6 ? abs(sin(phase)) * 8 : 0
                let sway = (row == 2 || row == 5) ? sin(phase) * 2 : 0
                let width = Double(cell) * 0.92
                let height = width * (1 + breath)
                let rectangle = CGRect(x: Double(column * cell) + (Double(cell) - width) / 2 + sway,
                    y: Double((7 - row) * cell) + 10 + hop, width: width, height: height)
                atlas.interpolationQuality = .high
                atlas.draw(keys[variant][row * 6 + key], in: rectangle)
                if variant == 0 {
                    metadata.append(["x": column * cell, "y": row * cell, "width": cell, "height": cell,
                        "duration": 0.08, "faceX": 128 + sway, "faceY": 104, "faceSize": 130,
                        "mouth": ["x": (Double(cell) - width) / 2 + sway + 73 / Double(sourceCell) * width,
                            "y": Double(cell) - 10 - hop - height + 72 / Double(sourceCell) * height,
                            "width": 38 / Double(sourceCell) * width, "height": 29 / Double(sourceCell) * height]])
                }
            }
        }
        let stem = page == 0 ? "atlas" : "atlas-\(page + 1)"
        save(atlas.makeImage()!, "\(stem)-\(variant == 0 ? "closed" : "open").png")
        if variant == 0 { save(atlas.makeImage()!, "\(stem).png") }
    }
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "frameWidth": cell,
        "frameHeight": cell, "frames": metadata], options: [.sortedKeys])
    try data.write(to: output.appendingPathComponent("pet-dog-\(page + 1).json"))
}
let manifest: [String: Any] = ["version": 1, "id": "detailed-dog", "name": "Detailed Dog",
    "columns": 6, "rows": 8, "sheetCount": 4, "hasSpeechFrames": true,
    "hue": 0, "saturation": 1, "accessory": "none"]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("look.json"))
print("Assembled 192 body frames and 384 aligned speech variants in \(output.path)")
