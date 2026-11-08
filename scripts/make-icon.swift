#!/usr/bin/env swift
// Renders the app icon into the asset catalog.
//
// Usage: swift scripts/make-icon.swift <AppIcon.appiconset> [variant]
//   variant: c-dark (default, the adopted icon), c, c2
//
//   c-dark  Folder on a navy ground. The folder front carries a hexagonal lattice whose centre seven cells are white.
//   c       The same folder on a pale blue ground.
//   c2      No folder: the lattice fills the whole tile, and the centre seven cells stand out with a soft shadow.
//
// Geometry is written on a 1024-unit canvas with y pointing down, the same as the SVG mock-ups it came from,
// so numbers here can be compared with those directly.
import AppKit

enum Variant: String, CaseIterable { case cDark = "c-dark", c, c2 }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A superellipse (n = 5) approximating the macOS icon tile.
func squircle(x: CGFloat, y: CGFloat, size: CGFloat) -> CGPath {
    let a = size / 2, cx = x + a, cy = y + a, n: CGFloat = 5
    let path = CGMutablePath()
    for i in 0..<240 {
        let t = CGFloat(i) / 240 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y: cy + a * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// A hexagon with a vertex pointing up.
func hexagon(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<6 {
        let t = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
        let p = CGPoint(x: x + r * cos(t), y: y + r * sin(t))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// Fills the current clip with a top-to-bottom gradient between y0 and y1.
func verticalGradient(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, _ y0: CGFloat, _ y1: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Hexagon centres on a lattice whose odd rows are shifted by half a cell.
func lattice(radius r: CGFloat, center: CGPoint, rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> [CGPoint] {
    let dx = sqrt(3) * r, dy = 1.5 * r
    var points: [CGPoint] = []
    for j in rows {
        for i in columns {
            points.append(CGPoint(x: center.x + CGFloat(i) * dx + (j & 1 == 1 ? dx / 2 : 0), y: center.y + CGFloat(j) * dy))
        }
    }
    return points
}

func drawFolder(_ ctx: CGContext) {
    // Back of the folder, with its tab.
    let back = CGMutablePath()
    back.move(to: CGPoint(x: 236, y: 262))
    back.addLine(to: CGPoint(x: 406, y: 262))
    back.addCurve(to: CGPoint(x: 452, y: 288), control1: CGPoint(x: 428, y: 262), control2: CGPoint(x: 440, y: 270))
    back.addLine(to: CGPoint(x: 474, y: 320))
    back.addLine(to: CGPoint(x: 788, y: 320))
    back.addCurve(to: CGPoint(x: 832, y: 364), control1: CGPoint(x: 814, y: 320), control2: CGPoint(x: 832, y: 338))
    back.addLine(to: CGPoint(x: 832, y: 664))
    back.addLine(to: CGPoint(x: 192, y: 664))
    back.addLine(to: CGPoint(x: 192, y: 306))
    back.addCurve(to: CGPoint(x: 236, y: 262), control1: CGPoint(x: 192, y: 280), control2: CGPoint(x: 210, y: 262))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(color(0x3d7fd4))
    ctx.fillPath()

    // Front of the folder.
    let frontRect = CGRect(x: 196, y: 372, width: 632, height: 430)
    let front = CGPath(roundedRect: frontRect, cornerWidth: 46, cornerHeight: 46, transform: nil)
    ctx.saveGState()
    ctx.addPath(front)
    ctx.clip()
    verticalGradient(ctx, 0x78b6f7, 0x3b80d9, frontRect.minY, frontRect.maxY)

    // Lattice on the front; the seven cells around the centre are filled white.
    let r: CGFloat = 54, center = CGPoint(x: 512, y: 590), dx = sqrt(3) * r
    for p in lattice(radius: r, center: center, rows: -5...5, columns: -8...8) {
        let d = hypot(p.x - center.x, p.y - center.y)
        ctx.addPath(hexagon(p.x, p.y, r * 0.9))
        if d < dx * 1.05 {
            ctx.setFillColor(color(0xffffff, d < 1 ? 0.95 : 0.75))
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(color(0xffffff, 0.22))
            ctx.setLineWidth(4)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // Light edge along the top of the front.
    ctx.setFillColor(color(0xffffff, 0.35))
    ctx.fill(CGRect(x: 196, y: 372, width: 632, height: 6))
}

func drawFilledLattice(_ ctx: CGContext, scale: CGFloat) {
    let r: CGFloat = 100, center = CGPoint(x: 512, y: 512), dx = sqrt(3) * r
    let points = lattice(radius: r, center: center, rows: -7...7, columns: -6...6)
    var raised: [(CGPoint, Bool)] = []
    for p in points {
        let d = hypot(p.x - center.x, p.y - center.y)
        if d < dx * 1.05 { raised.append((p, d < 1)); continue }
        ctx.addPath(hexagon(p.x, p.y, r * 0.9))
        ctx.setStrokeColor(color(0xffffff, 0.22))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    // The centre seven: light top-to-bottom gradient, white rim, soft shadow below.
    for (p, isCenter) in raised {
        let hex = hexagon(p.x, p.y, r * 0.9)
        ctx.saveGState()
        // Shadow offsets are in device space, where y points up.
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 14 * scale, color: color(0x123f80, 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(hex)
        ctx.clip()
        if isCenter {
            verticalGradient(ctx, 0xffffff, 0xd6e6f8, p.y - r * 0.9, p.y + r * 0.9)
        } else {
            verticalGradient(ctx, 0xf4f9ff, 0xc3daf4, p.y - r * 0.9, p.y + r * 0.9)
        }
        ctx.restoreGState()
        ctx.addPath(hex)
        ctx.setStrokeColor(color(0xffffff, 0.9))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

func render(_ variant: Variant, size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(size) / 1024
    // Work on a 1024-unit canvas with y pointing down.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)

    // Apple's macOS icon grid: the tile is 824 units inside the 1024 canvas.
    let body = squircle(x: 100, y: 100, size: 824)
    let ground: (UInt32, UInt32) = switch variant {
    case .cDark: (0x22355c, 0x0b1226)
    case .c: (0xeef4fb, 0xcddcee)
    case .c2: (0x78b6f7, 0x3b80d9)
    }

    // Tile with its drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: color(0x000000, 0.25))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(body)
    ctx.clip()
    verticalGradient(ctx, ground.0, ground.1, 100, 924)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    switch variant {
    case .cDark, .c: drawFolder(ctx)
    case .c2: drawFilledLattice(ctx, scale: scale)
    }
    ctx.restoreGState()

    // Faint light rim around the tile.
    ctx.addPath(body)
    ctx.setStrokeColor(color(0xffffff, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()

    return rep.representation(using: .png, properties: [:])!
}

// When run through `swift file.swift`, newer toolchains pass the interpreter's own flags first and the script's
// arguments after "--".
let all = CommandLine.arguments
let arguments = all.firstIndex(of: "--").map { Array(all[($0 + 1)...]) } ?? Array(all.dropFirst())
guard arguments.count >= 1, let variant = Variant(rawValue: arguments.count >= 2 ? arguments[1] : Variant.cDark.rawValue) else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <AppIcon.appiconset> [\(Variant.allCases.map(\.rawValue).joined(separator: "|"))]\n".data(using: .utf8)!)
    exit(1)
}
let directory = URL(fileURLWithPath: arguments[0])
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        try render(variant, size: points * scale).write(to: directory.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
