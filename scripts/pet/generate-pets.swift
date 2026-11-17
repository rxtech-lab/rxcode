#!/usr/bin/env swift
import AppKit

// Deterministic vector artwork keeps each mouth pair pixel-aligned while the
// body moves. No raster background or source image is included in these sheets.
let cell = 128
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "RxCode/Resources/Pet")
let shell = NSColor(calibratedRed: 0.89, green: 0.94, blue: 0.98, alpha: 1)
let dark = NSColor(calibratedRed: 0.025, green: 0.09, blue: 0.14, alpha: 1)
let cyan = NSColor(calibratedRed: 0.16, green: 0.94, blue: 1, alpha: 1)
let ink = NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.24, alpha: 1)
let pink = NSColor(calibratedRed: 0.96, green: 0.46, blue: 0.61, alpha: 1)
func shape(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func oval(_ rect: NSRect, _ color: NSColor, outline: NSColor? = nil) {
    let path = NSBezierPath(ovalIn: rect)
    color.setFill(); path.fill()
    if let outline { outline.setStroke(); path.lineWidth = 1.5; path.stroke() }
}
func polygon(_ points: [NSPoint], _ color: NSColor, outline: NSColor? = nil) {
    let path = NSBezierPath()
    path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
    color.setFill(); path.fill()
    if let outline { outline.setStroke(); path.lineWidth = 1.5; path.lineJoinStyle = .round; path.stroke() }
}
func line(_ from: NSPoint, _ to: NSPoint, color: NSColor = ink, width: CGFloat = 2.5) {
    let path = NSBezierPath(); path.move(to: from); path.line(to: to)
    path.lineWidth = width; path.lineCapStyle = .round; color.setStroke(); path.stroke()
}
func smile(x: CGFloat, y: CGFloat, width: CGFloat, open: Bool, electronic: Bool = false) {
    if electronic {
        shape(NSRect(x: x, y: y - (open ? 3 : 0), width: width, height: open ? 10 : 3), open ? 4 : 1.5, cyan)
        if open { shape(NSRect(x: x + 2, y: y - 1, width: width - 4, height: 6), 2, dark) }
    } else if open {
        oval(NSRect(x: x, y: y - 4, width: width, height: width * 0.72), ink)
        oval(NSRect(x: x + width * 0.20, y: y - 3, width: width * 0.60, height: width * 0.28), pink)
    } else {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y + 2))
        path.curve(to: NSPoint(x: x + width, y: y + 2),
            controlPoint1: NSPoint(x: x + width * 0.25, y: y - 3),
            controlPoint2: NSPoint(x: x + width * 0.75, y: y - 3))
        ink.setStroke(); path.lineWidth = 2.5; path.lineCapStyle = .round; path.stroke()
    }
}
func eyes(y: CGFloat, look: CGFloat, closed: Bool) {
    for x: CGFloat in [49, 79] {
        if closed { line(NSPoint(x: x - 4 + look, y: y), NSPoint(x: x + 4 + look, y: y + 1)) }
        else {
            oval(NSRect(x: x - 4 + look, y: y - 4, width: 9, height: 12), ink)
            oval(NSRect(x: x - 2 + look, y: y + 3, width: 3, height: 3.5), .white)
        }
    }
}
for kind in ["robot", "dog", "cat", "puff"] {
    for mouthState in ["rest", "closed", "open"] {
        for page in 0..<4 {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cell * 6, pixelsHigh: cell * 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: cell * 6, height: cell * 8).fill(using: .copy)
            var frames: [[String: Any]] = []
            for row in 0..<8 {
                for col in 0..<6 {
                    let phase = Double(page * 6 + col) / 24 * .pi * 2
                    let sway = sin(phase)
                    let hop = row == 6 ? abs(sway) * 8 : 0
                    let breath = row == 0 ? sway * 1.5 : row == 3 ? sway : 0
                    let walk = row == 5 ? sway * 5 : 0
                    let arm = row == 4 ? 12 + sway * 8 : row == 1 ? sway * 5 : row == 6 ? 12 : 0
                    let look = row == 2 ? sway * 3 : 0
                    let blink = row == 3 || (col == 4 && page == 0)
                    let headX = kind == "robot" ? 0 : (row == 2 ? sway * 2 : row == 5 ? sway : 0)
                    let headY = kind == "robot" ? 0 : (row == 7 ? -5 : row == 1 ? abs(sway) * -2 : 0)
                    NSGraphicsContext.saveGraphicsState()
                    let transform = NSAffineTransform()
                    transform.translateX(by: CGFloat(col * cell), yBy: CGFloat((7 - row) * cell) + hop + breath)
                    transform.concat()
                    if kind == "robot" {
                        shape(NSRect(x: 40, y: 12 + walk, width: 18, height: 11), 5, dark)
                        shape(NSRect(x: 70, y: 12 - walk, width: 18, height: 11), 5, dark)
                        shape(NSRect(x: 38, y: 23, width: 52, height: 31), 12, shell)
                        shape(NSRect(x: 55, y: 34, width: 18, height: 7), 3, cyan)
                        shape(NSRect(x: 23, y: 28, width: 12, height: 28), 6, shell)
                        shape(NSRect(x: 93, y: 28 + arm, width: 12, height: 28), 6, shell)
                        shape(NSRect(x: 28, y: 53, width: 72, height: 54), 18, shell)
                        shape(NSRect(x: 35, y: 60, width: 58, height: 37), 12, dark)
                        let eyeHeight: CGFloat = blink ? 2 : 9
                        shape(NSRect(x: 46 + look, y: 80, width: 7, height: eyeHeight), 3, cyan)
                        shape(NSRect(x: 75 + look, y: 80, width: 7, height: eyeHeight), 3, cyan)
                        smile(x: 57, y: 65, width: 14, open: mouthState == "open", electronic: true)
                        shape(NSRect(x: 62, y: 107, width: 4, height: 8), 2, dark)
                        shape(NSRect(x: 59, y: 114, width: 10, height: 6), 3, cyan)
                    } else {
                        let fur: NSColor = kind == "dog" ? NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.43, alpha: 1)
                            : kind == "cat" ? NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.92, alpha: 1)
                            : NSColor(calibratedRed: 1, green: 0.70, blue: 0.80, alpha: 1)
                        let edge: NSColor = kind == "dog" ? NSColor(calibratedRed: 0.63, green: 0.39, blue: 0.19, alpha: 1)
                            : kind == "cat" ? NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.61, alpha: 1)
                            : NSColor(calibratedRed: 0.80, green: 0.38, blue: 0.52, alpha: 1)
                        let cream = NSColor(calibratedRed: 1, green: 0.96, blue: 0.88, alpha: 1)
                        if kind != "puff" {
                            oval(NSRect(x: 22 + sway * 2, y: 22, width: 27, height: 29), fur, outline: edge)
                            oval(NSRect(x: 37, y: 16, width: 54, height: 54), fur, outline: edge)
                            oval(NSRect(x: 49, y: 23, width: 30, height: 33), cream)
                        }
                        oval(NSRect(x: 35, y: 10 + walk, width: 24, height: 14), fur, outline: edge)
                        oval(NSRect(x: 70, y: 10 - walk, width: 24, height: 14), fur, outline: edge)
                        oval(NSRect(x: 26, y: 34, width: 17, height: 25), fur, outline: edge)
                        oval(NSRect(x: 86, y: 34 + arm, width: 17, height: 25), fur, outline: edge)
                        NSGraphicsContext.saveGraphicsState()
                        let head = NSAffineTransform(); head.translateX(by: headX, yBy: headY); head.concat()
                        if kind == "cat" {
                            polygon([NSPoint(x: 29, y: 84), NSPoint(x: 29, y: 115), NSPoint(x: 52, y: 102)], fur, outline: edge)
                            polygon([NSPoint(x: 76, y: 102), NSPoint(x: 99, y: 115), NSPoint(x: 99, y: 84)], fur, outline: edge)
                            polygon([NSPoint(x: 34, y: 96), NSPoint(x: 34, y: 107), NSPoint(x: 45, y: 101)], pink)
                            polygon([NSPoint(x: 83, y: 101), NSPoint(x: 94, y: 107), NSPoint(x: 94, y: 96)], pink)
                        }
                        oval(kind == "puff" ? NSRect(x: 24, y: 24, width: 80, height: 83) : NSRect(x: 25, y: 52, width: 78, height: 55), fur, outline: edge)
                        if kind == "dog" {
                            let droop: CGFloat = row == 7 ? -5 : 0
                            oval(NSRect(x: 20, y: 59 + droop, width: 22, height: 43), edge)
                            oval(NSRect(x: 86, y: 59 + droop, width: 22, height: 43), edge)
                            oval(NSRect(x: 37, y: 55, width: 54, height: 29), cream)
                        } else if kind == "cat" {
                            oval(NSRect(x: 42, y: 55, width: 44, height: 26), cream)
                        } else {
                            oval(NSRect(x: 56, y: 99, width: 19, height: 15), fur, outline: edge)
                        }
                        eyes(y: 82, look: look, closed: blink)
                        oval(NSRect(x: 36, y: 70, width: 10, height: 5), pink.withAlphaComponent(0.50))
                        oval(NSRect(x: 83, y: 70, width: 10, height: 5), pink.withAlphaComponent(0.50))
                        if kind != "puff" { oval(NSRect(x: 61, y: 74, width: 7, height: 4), kind == "dog" ? ink : pink) }
                        if row == 7 {
                            line(NSPoint(x: 45, y: 96), NSPoint(x: 55, y: 99), color: edge, width: 2)
                            line(NSPoint(x: 74, y: 99), NSPoint(x: 84, y: 96), color: edge, width: 2)
                        }
                        smile(x: 57, y: 65, width: 14, open: mouthState == "open")
                        NSGraphicsContext.restoreGraphicsState()
                        if row == 4 || row == 6 {
                            oval(NSRect(x: 99, y: 55 + arm, width: 17, height: 23), fur, outline: edge)
                            oval(NSRect(x: 104, y: 62 + arm, width: 7, height: 8), pink.withAlphaComponent(0.65))
                        } else if row == 1 {
                            shape(NSRect(x: 78, y: 32, width: 24, height: 17), 4, edge)
                            line(NSPoint(x: 82, y: 41), NSPoint(x: 96, y: 41), color: cream, width: 2)
                            oval(NSRect(x: 89, y: 28 + abs(sway) * 4, width: 15, height: 14), fur, outline: edge)
                        }
                    }
                    frames.append(["x": col * cell, "y": row * cell, "width": cell, "height": cell,
                        "faceX": 64 + headX, "faceY": 46 - hop - breath - headY, "faceSize": 58, "duration": 0.08,
                        "mouth": ["x": 57 + headX, "y": 60 - hop - breath - headY, "width": 14, "height": 3]])
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let manifest: [String: Any] = ["version": 1, "frameWidth": cell, "frameHeight": cell, "frames": frames]
            if mouthState == "rest" {
                try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("pet-\(kind)-\(page + 1).json"))
            }
            let suffix = mouthState == "rest" ? "" : "-\(mouthState)"
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("pet-\(kind)-\(page + 1)\(suffix).png"))
        }
    }
}
