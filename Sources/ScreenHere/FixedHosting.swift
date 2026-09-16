import AppKit
import SwiftUI

/// SwiftUI content for a borderless panel whose size is decided once, here.
///
/// An NSHostingView that is a window's content view keeps resizing the window
/// to its own ideal size. For the toast under the menu bar, that resizing and
/// the safe area invalidating on every frame change fed each other until
/// AppKit threw ("more Update Constraints in Window passes than there are
/// views in the window") and took ScreenHere down. Nested in a plain view,
/// with sizing turned off, the hosting view can only lay out inside its frame.
@MainActor
enum FixedHosting {
    /// A view showing `root` at `size`, or at its natural size when nil.
    static func view<Content: View>(_ root: Content, size: NSSize? = nil) -> NSView {
        let hosting = NSHostingView(rootView: root.ignoresSafeArea())
        let size = size ?? {
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize
        }()
        // Measured first: without sizing options the fitting size is zero.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: hosting.frame)
        container.addSubview(hosting)
        return container
    }
}
