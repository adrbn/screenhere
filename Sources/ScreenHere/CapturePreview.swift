import AppKit
import SwiftUI

/// The preview that slides into the corner after a capture — on the display
/// that was captured, which is the one thing macOS's own preview will not do.
///
/// A borderless floating window rather than anything in the panel: it has to
/// sit above every app, on a screen the user may not have focused, and survive
/// a Space change while it is up.
@MainActor
final class CapturePreview {
    static let shared = CapturePreview()

    private var window: NSWindow?
    private var dismissal: Timer?

    /// How long it stays before fading out, matching macOS's own cadence.
    private static let lifetime: TimeInterval = 6

    /// Show `image` in the corner of `screen`. `file` backs dragging and the
    /// click-through to Finder; without one the preview is display-only.
    func show(image: NSImage, file: URL?, on screen: NSScreen) {
        dismiss(animated: false)

        let size = Self.size(for: image)
        let view = CapturePreviewView(
            image: image, file: file,
            onOpen: { [weak self] in
                if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                self?.dismiss(animated: true)
            },
            onDismiss: { [weak self] in self?.dismiss(animated: true) })

        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view)
        // The window's own corners are square, so anything the card painted
        // outside its rounded shape stayed visible at the angles as grey
        // wedges. Round and clip the layer itself, and let AppKit cast the
        // shadow from that shape rather than drawing one inside.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Self.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        hosting.layer?.backgroundColor = .clear
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.isMovable = false
        // Follow the user across Spaces; a preview left behind on Space 1 is
        // worse than none, and it must never take focus from what they are doing.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrameOrigin(Self.origin(for: size, on: screen))
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }

        self.window = window
        dismissal = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.dismiss(animated: true) }
        }
    }

    func dismiss(animated: Bool) {
        dismissal?.invalidate()
        dismissal = nil
        guard let window else { return }
        self.window = nil

        guard animated else { return window.orderOut(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    // MARK: - Geometry

    /// Keeps the capture's aspect ratio inside a sensible box, the way macOS's
    /// own preview does — a portrait display should not produce a wide card.
    static let cornerRadius: CGFloat = 10

    /// The card's own margin around the image, in points.
    static let inset: CGFloat = 4

    static func size(for image: NSImage) -> NSSize {
        let maximum = NSSize(width: 232, height: 150)
        let source = image.size
        guard source.width > 0, source.height > 0 else { return maximum }
        let scale = min(maximum.width / source.width, maximum.height / source.height)
        let image = NSSize(width: max(80, source.width * scale),
                           height: max(56, source.height * scale))
        // The window covers the whole card. Sizing it to the image alone left
        // the card's margin outside the window, where a transparent background
        // showed the desktop through as a grey halo.
        return NSSize(width: image.width + inset * 2, height: image.height + inset * 2)
    }

    /// Bottom-right of the captured screen, clear of the Dock.
    static func origin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let margin: CGFloat = 20
        let area = screen.visibleFrame
        return NSPoint(x: area.maxX - size.width - margin,
                       y: area.minY + margin)
    }
}

/// The card itself: the capture, a soft shadow, and the two gestures people
/// expect from macOS's preview — click to reveal, drag to carry the file out.
private struct CapturePreviewView: View {
    let image: NSImage
    let file: URL?
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .onTapGesture(perform: onOpen)

            if hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(5)
                .transition(.opacity)
            }
        }
        .padding(CapturePreview.inset)
        // A real surface behind the image, the way macOS's own preview is a
        // card rather than a bare screenshot floating on the desktop.
        .background(
            RoundedRectangle(cornerRadius: CapturePreview.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Dragging carries the file, so it can be dropped into a message or a
        // document exactly like macOS's own preview.
        .modifier(DragOut(file: file))
    }
}

private struct DragOut: ViewModifier {
    let file: URL?

    func body(content: Content) -> some View {
        if let file {
            content.onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
        } else {
            content
        }
    }
}
