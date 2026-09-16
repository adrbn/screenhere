import AppKit
import SwiftUI

/// A short confirmation pill at the top of the screen under the pointer, just
/// below the menu bar — "Copied 12 words" — that never takes focus or a click.
@MainActor
enum Toast {
    private static var window: NSPanel?
    private static var dismissal: DispatchWorkItem?
    /// Between the menu bar and the pill's shadow padding.
    private static let topGap: CGFloat = 14

    static func show(_ message: String, systemImage: String) {
        dismissal?.cancel()
        window?.orderOut(nil)

        let content = FixedHosting.view(ToastView(message: message, systemImage: systemImage))
        let size = content.frame.size

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let screen = PreviewCoordinator.screenUnderPointer() ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - Self.topGap))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        window = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .padding(12)   // room for the shadow
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}
