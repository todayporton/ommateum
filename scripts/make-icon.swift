#!/usr/bin/env swift
// Renders the app icon (a compound eye: "ommatidia" of hexagonal facets) into the asset catalog.
// Usage: swift scripts/make-icon.swift Ommateum/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // Apple's macOS icon grid: the shape fills about 80% of the canvas.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let clip = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.10, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.10, green: 0.22, blue: 0.36, alpha: 1)])!
        .draw(in: clip, angle: 90)
    clip.addClip()
    let radius = tile.width * 0.082
    let center = NSPoint(x: s / 2, y: s / 2)
    let width = sqrt(3) * radius
    let maxDistance = tile.width * 0.40
    for row in -6...6 {
        for column in -6...6 {
            let x = center.x + (CGFloat(column) + (row % 2 == 0 ? 0 : 0.5)) * width
            let y = center.y + CGFloat(row) * radius * 1.5
            let distance = hypot(x - center.x, y - center.y)
            guard distance <= maxDistance else { continue }
            let path = NSBezierPath()
            for corner in 0..<6 {
                let angle = CGFloat(corner) * .pi / 3 + .pi / 6
                let r = radius * 0.88
                let point = NSPoint(x: x + r * cos(angle), y: y + r * sin(angle))
                corner == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.close()
            let t = distance / maxDistance
            let color = NSColor(srgbRed: 0.25 + 0.20 * t, green: 0.85 - 0.45 * t, blue: 0.95 - 0.10 * t, alpha: 1)
            NSGradient(colors: [color.highlight(withLevel: 0.35)!, color])!.draw(in: path, angle: -60)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        try render(size: points * scale).write(to: directory.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
