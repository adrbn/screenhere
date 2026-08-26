import AppKit
import CoreGraphics

/// A display as `screencapture` sees it: an identifier plus its global bounds
/// in CoreGraphics coordinates (origin top-left, y grows downwards).
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

/// Resolves which display the pointer is on, as a `screencapture -D<n>` index.
enum CursorDisplay {

    /// 1-based index for `screencapture -D<n>`.
    ///
    /// `displays` must be in `CGGetActiveDisplayList` order: that order is
    /// exactly what `-D` indexes (verified on macOS 27.0 — `-D1` returned the
    /// main display at 5120×2880, `-D2` the built-in one at 3360×2100).
    /// Falls back to the main display when the pointer sits outside every
    /// display, and to 1 when the display list could not be read at all.
    static func captureIndex(for point: CGPoint,
                             in displays: [DisplayInfo],
                             mainDisplayID: CGDirectDisplayID) -> Int {
        if let hit = displays.firstIndex(where: { $0.bounds.contains(point) }) {
            return hit + 1
        }
        if let main = displays.firstIndex(where: { $0.id == mainDisplayID }) {
            return main + 1
        }
        return 1
    }

    // MARK: - Live system state

    /// Active displays in `CGGetActiveDisplayList` order. Empty if the list
    /// cannot be read, which the pure logic above degrades gracefully on.
    static func activeDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0)) }
    }

    /// Pointer position in global CoreGraphics coordinates. Read from a
    /// synthesised event rather than `NSEvent.mouseLocation` so it needs no
    /// coordinate flip and stays correct without a key window.
    static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The index to hand `screencapture` right now. Recomputed on every call —
    /// never cached, so hot-plugging a display between two captures is fine.
    static func currentCaptureIndex() -> Int {
        captureIndex(for: cursorLocation(),
                     in: activeDisplays(),
                     mainDisplayID: CGMainDisplayID())
    }

    /// Human-readable name of a display, for the map labels.
    static func name(of id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value == id
        }?.localizedName
    }

    /// Human-readable name of the display holding `point`, for the menu.
    static func displayName(at point: CGPoint) -> String? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayBounds(number.uint32Value).contains(point)
        }?.localizedName
    }
}
