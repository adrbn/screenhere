import AppKit

/// The menu-bar glyph: a screen with a pointer in it — the app's whole idea at
/// 18×16. Drawn in code rather than taken from SF Symbols because no symbol
/// says "this display, not that one".
///
/// Deliberately minimal: a hairline frame and a small solid pointer. Earlier
/// attempts stacked two overlapping displays and knocked the pointer out of the
/// near one; at menu-bar size that collapsed into an unreadable checkerboard.
enum MenuBarIcon {

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
            pointer(in: NSRect(x: 7.0, y: 6.4, width: 5.4, height: 5.4)).fill()
            return true
        }
        image.isTemplate = true   // let the menu bar tint it for light/dark
        return image
    }

    /// The pointer, authored on a 100-unit square so the same silhouette can be
    /// scaled into the app icon.
    static func pointer(in r: NSRect) -> NSBezierPath {
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
}
