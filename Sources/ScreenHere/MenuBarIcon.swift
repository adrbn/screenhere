import AppKit

/// The menu-bar glyph: a screen with a pointer in it — the app's whole idea at
/// 18×16. Drawn in code rather than taken from SF Symbols because no symbol
/// says "this display, not that one".
///
/// Deliberately minimal: a hairline frame and a small solid pointer. Earlier
/// attempts stacked two overlapping displays and knocked the pointer out of the
/// near one; at menu-bar size that collapsed into an unreadable checkerboard.
enum MenuBarIcon {

    /// Built once. A fresh NSImage per render makes AppKit re-snapshot the
    /// status item even when nothing about it changed.
    static let status: NSImage = statusImage()

    static func statusImage() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let frame = NSBezierPath(
                roundedRect: NSRect(x: 2, y: 4.3, width: 14, height: 9.8),
                xRadius: 2, yRadius: 2)
            frame.lineWidth = 1.2
            NSColor.black.setStroke()
            frame.stroke()

            NSColor.black.setFill()
            pointer(in: NSRect(x: 7.2, y: 5.4, width: 4, height: 7)).fill()
            return true
        }
        image.isTemplate = true   // let the menu bar tint it for light/dark
        return image
    }

    /// The pointer in the macOS arrow's proportions, the same outline as the app
    /// icon and the panel's map: tip at the top left, y growing downwards.
    static let pointerOutline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 75), CGPoint(x: 19, y: 60), CGPoint(x: 32, y: 97),
        CGPoint(x: 48, y: 91), CGPoint(x: 33, y: 55), CGPoint(x: 56, y: 54),
    ]
    static let pointerSize = CGSize(width: 56, height: 97)

    /// The pointer at the height of `r`, keeping its own width so it is never
    /// squashed.
    static func pointer(in r: NSRect) -> NSBezierPath {
        let scale = r.height / pointerSize.height
        let p = NSBezierPath()
        for (index, point) in pointerOutline.enumerated() {
            let q = NSPoint(x: r.minX + point.x * scale, y: r.maxY - point.y * scale)
            if index == 0 { p.move(to: q) } else { p.line(to: q) }
        }
        p.close()
        return p
    }
}
