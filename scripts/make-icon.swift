#!/usr/bin/env swift
import AppKit

// Generates the ScreenHere app icon: a flat violet squircle, a hairline white
// screen, and the same pointer silhouette the menu-bar glyph uses. Deliberately
// minimal — no gradient, no sheen, no second display. Renders the vector at
// every iconset size; the caller runs `iconutil` for the .icns.

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.iconset"

let variants: [(String, Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024),
]

/// Same silhouette as Sources/ScreenHere/MenuBarIcon.swift, on a 100-unit square.
func pointer(in r: NSRect) -> NSBezierPath {
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: r.minX + x / 100 * r.width, y: r.minY + y / 100 * r.height)
    }
    let p = NSBezierPath()
    p.move(to: P(0, 100)); p.line(to: P(0, 22))
    p.line(to: P(24, 46)); p.line(to: P(40, 15))
    p.line(to: P(58, 24)); p.line(to: P(42, 54))
    p.line(to: P(76, 58)); p.close()
    return p
}

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.cgContext.interpolationQuality = .high

    // Authored on a 1024 grid and scaled to `size`.
    let f = size / 1024.0
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * f, y: y * f, width: w * f, height: h * f)
    }

    let violet = NSColor(srgbRed: 0.49, green: 0.31, blue: 0.94, alpha: 1)
    let white = NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1)

    // Apple's icon grid: 824 of content inside 1024, corner radius ~185.
    violet.setFill()
    NSBezierPath(roundedRect: R(100, 100, 824, 824), xRadius: 185 * f, yRadius: 185 * f).fill()

    let screen = NSBezierPath(roundedRect: R(268, 310, 488, 372), xRadius: 44 * f, yRadius: 44 * f)
    screen.lineWidth = 34 * f
    white.setStroke()
    screen.stroke()

    white.setFill()
    pointer(in: R(400, 380, 224, 224)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, px) in variants {
    let rep = draw(CGFloat(px))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(name)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

print("wrote \(variants.count) images to \(outDir)")
