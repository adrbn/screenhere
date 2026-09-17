import AppKit
import CoreGraphics
import os

/// A window as the window server lists it, reduced to what picking one needs.
struct ListedWindow: Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    let alpha: Double
    /// Global CoreGraphics coordinates, like the pointer.
    let bounds: CGRect
}

/// Finds the window the pointer is on, for capturing just that window.
enum WindowUnderPointer {
    /// Below this, it is a tooltip or a handle rather than a window anyone
    /// means to capture.
    static let minimumSide: CGFloat = 40

    /// Apps' windows sit below this layer, normal ones at 0 and floating ones
    /// (Picture in Picture, utility panels) a little above. From here up it is
    /// the system's: the Dock, the menu bar, menus.
    static let systemLayer = Int(CGWindowLevelForKey(.dockWindow))

    /// At times macOS draws the pointer in a small window of its own, at this
    /// layer and right where the pointer is. Nothing here is a window anyone
    /// is on.
    static let pointerLayer = Int(CGWindowLevelForKey(.cursorWindow))

    private static let log = Logger(subsystem: "com.screenhere.app", category: "window-capture")

    /// `windows` in front-to-back order, as the window server lists them.
    /// Nil when the pointer is on no window: the desktop, the Dock, the menu
    /// bar or an open menu.
    static func pick(at point: CGPoint, in windows: [ListedWindow],
                     displays: [CGRect], ownPID: pid_t) -> CGWindowID? {
        for window in windows where window.alpha > 0 && window.bounds.contains(point) {
            if window.ownerPID == ownPID || window.layer < 0 || window.layer >= pointerLayer { continue }
            // A layer spread over a whole display is an overlay (dimming,
            // focus tools), not something the pointer is on. A normal window
            // that size is an app in full screen, and is.
            if window.layer != 0, displays.contains(where: { window.bounds.contains($0) }) { continue }
            if window.layer < systemLayer {
                guard window.bounds.width >= minimumSide,
                      window.bounds.height >= minimumSide else { continue }
                return window.id
            }
            // The system's own UI in front of the windows is what the pointer
            // is on.
            return nil
        }
        return nil
    }

    static func listedWindows() -> [ListedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return ListedWindow(id: id, ownerPID: owner, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    static func current() -> CGWindowID? {
        let point = CursorDisplay.cursorLocation()
        let windows = listedWindows()
        let picked = pick(at: point, in: windows, displays: CursorDisplay.activeDisplays().map(\.bounds),
                          ownPID: ProcessInfo.processInfo.processIdentifier)
        if picked == nil {
            // Says why a window capture became a display capture: layers and
            // sizes only, never titles or owners.
            let under = windows.filter { $0.alpha > 0 && $0.bounds.contains(point) }
                .map { "layer \($0.layer) \(Int($0.bounds.width))×\(Int($0.bounds.height))" }
            log.notice("No window to capture. Under the pointer: \(under.joined(separator: ", "), privacy: .public)")
        }
        return picked
    }
}

enum WindowCapture {
    /// Captures the window under the pointer, or its display when the pointer
    /// is on no window, so the key press is never wasted.
    static func run(destination: CaptureDestination,
                    window: () -> CGWindowID? = WindowUnderPointer.current,
                    displayIndex: () -> Int = CursorDisplay.currentCaptureIndex,
                    runner: ([String]) -> Void = { CaptureRunner.run(arguments: $0) }) {
        if let window = window() {
            runner(CaptureRunner.arguments(destination: destination, windowID: window))
        } else {
            runner(CaptureRunner.arguments(destination: destination, displayIndex: displayIndex()))
        }
    }
}
