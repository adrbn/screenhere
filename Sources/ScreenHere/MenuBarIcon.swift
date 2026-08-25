import AppKit

/// The menu-bar glyph: two overlapping displays with a pointer on the nearer
/// one — the app's whole idea in 18×16 points. Drawn in code rather than taken
/// from SF Symbols because no symbol says "this display, not that one", and a
/// single even-odd path stays crisp as a template image.
enum MenuBarIcon {

    static func statusImage() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()

            // Far display: a frame, offset up and to the right.
            path.append(NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6.5, width: 10.5, height: 7.5),
                                     xRadius: 1.5, yRadius: 1.5))
            path.append(NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 7.5, height: 4.5),
                                     xRadius: 0.5, yRadius: 0.5))

            // Near display: filled, drawn over the far one.
            path.append(NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 11, height: 8),
                                     xRadius: 1.5, yRadius: 1.5))
            path.append(NSBezierPath(rect: NSRect(x: 5.5, y: 0.5, width: 2, height: 1.5)))

            // Pointer, punched out of the near display by the even-odd rule.
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: 5, y: 8.5))
            pointer.line(to: NSPoint(x: 5, y: 3.5))
            pointer.line(to: NSPoint(x: 6.4, y: 4.9))
            pointer.line(to: NSPoint(x: 7.3, y: 3.1))
            pointer.line(to: NSPoint(x: 8.4, y: 3.6))
            pointer.line(to: NSPoint(x: 7.5, y: 5.4))
            pointer.line(to: NSPoint(x: 9.4, y: 5.6))
            pointer.close()
            path.append(pointer)

            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true   // let the menu bar tint it for light/dark
        return image
    }
}
