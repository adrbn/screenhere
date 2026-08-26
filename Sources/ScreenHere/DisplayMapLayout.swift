import CoreGraphics

/// Squeezes the real display arrangement into the small map the panel draws.
///
/// Pure geometry, so the map can be trusted: same relative positions, same
/// aspect ratio, and a pointer that lands inside the display it is really on.
enum DisplayMapLayout {

    struct Fitted {
        let rects: [CGRect]
        let pointer: CGPoint?
    }

    /// `displays` are global CoreGraphics bounds (origin top-left), in the order
    /// they should be drawn. `pointer` is in the same space.
    static func fit(displays: [CGRect],
                    pointer: CGPoint?,
                    into canvas: CGSize,
                    padding: CGFloat) -> Fitted {
        guard !displays.isEmpty else { return Fitted(rects: [], pointer: nil) }

        let union = displays.dropFirst().reduce(displays[0]) { $0.union($1) }
        guard union.width > 0, union.height > 0 else {
            return Fitted(rects: displays.map { _ in .zero }, pointer: nil)
        }

        let box = CGSize(width: max(0, canvas.width - padding * 2),
                         height: max(0, canvas.height - padding * 2))
        // One shared scale for both axes: scaling them independently would
        // stretch the displays and misrepresent the arrangement.
        let scale = min(box.width / union.width, box.height / union.height)
        // Centre the scaled arrangement in whatever space is left over.
        let offsetX = padding + (box.width - union.width * scale) / 2
        let offsetY = padding + (box.height - union.height * scale) / 2

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offsetX + (p.x - union.minX) * scale,
                    y: offsetY + (p.y - union.minY) * scale)
        }

        let rects = displays.map { d in
            CGRect(origin: map(d.origin),
                   size: CGSize(width: d.width * scale, height: d.height * scale))
        }
        return Fitted(rects: rects, pointer: pointer.map(map))
    }
}
