#!/usr/bin/env swift
import AppKit

// Generates the ScreenHere app icon: a violet squircle carrying the same motif
// as the menu-bar glyph — two overlapping displays with a pointer knocked out
// of the near one. Renders the vector at every iconset size so small sizes stay
// crisp; the caller runs `iconutil` to produce the .icns.

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

    // Everything below is authored on a 1024 grid and scaled to `size`.
    let f = size / 1024.0
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * f, y: y * f, width: w * f, height: h * f)
    }
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * f, y: y * f) }

    // --- background squircle (Apple grid: 824 content in 1024, radius ~185) ---
    let bg = NSBezierPath(roundedRect: R(100, 100, 824, 824), xRadius: 185 * f, yRadius: 185 * f)
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.13, blue: 0.55, alpha: 1),   // deep indigo (bottom)
        NSColor(srgbRed: 0.56, green: 0.31, blue: 0.96, alpha: 1),   // bright violet (top)
    ])!
    grad.draw(in: bg, angle: 90)

    let sheen = NSBezierPath(roundedRect: R(100, 540, 824, 384), xRadius: 185 * f, yRadius: 185 * f)
    NSColor(white: 1, alpha: 0.06).setFill()
    sheen.fill()

    let white = NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1)

    // --- far display: an outline frame, up and to the right ---
    let far = NSBezierPath()
    far.append(NSBezierPath(roundedRect: R(500, 520, 320, 230), xRadius: 26 * f, yRadius: 26 * f))
    far.append(NSBezierPath(roundedRect: R(534, 554, 252, 162), xRadius: 10 * f, yRadius: 10 * f))
    far.windingRule = .evenOdd
    NSColor(white: 1, alpha: 0.45).setFill()
    far.fill()

    // --- near display: solid, with the pointer punched out of it ---
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
    shadow.shadowBlurRadius = 30 * f
    shadow.shadowOffset = NSSize(width: 0, height: -12 * f)
    shadow.set()

    let near = NSBezierPath()
    near.append(NSBezierPath(roundedRect: R(210, 300, 400, 285), xRadius: 32 * f, yRadius: 32 * f))
    near.append(NSBezierPath(rect: R(370, 250, 80, 55)))                                  // stand
    near.append(NSBezierPath(roundedRect: R(320, 225, 180, 42), xRadius: 18 * f, yRadius: 18 * f))

    let pointer = NSBezierPath()
    pointer.move(to: P(330, 520))
    pointer.line(to: P(330, 330))
    pointer.line(to: P(382, 382))
    pointer.line(to: P(416, 314))
    pointer.line(to: P(458, 332))
    pointer.line(to: P(424, 400))
    pointer.line(to: P(496, 408))
    pointer.close()
    near.append(pointer)

    near.windingRule = .evenOdd     // the pointer becomes a hole onto the gradient
    white.setFill()
    near.fill()

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
