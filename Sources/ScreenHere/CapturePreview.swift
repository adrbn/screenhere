import AppKit
import SwiftUI

/// The preview that slides into the corner after a capture — on the display
/// that was captured, which is the one thing macOS's own preview will not do.
///
/// A borderless floating window rather than anything in the panel: it has to
/// sit above every app, on a screen the user may not have focused, and survive
/// a Space change while it is up.
/// How far the card has been pushed, and how far it may go.
@MainActor
final class PreviewState: ObservableObject {
    @Published var offset: CGFloat = 0
    /// Room to the right of the card inside the window, so the card can travel
    /// while the window stays put under the pointer.
    static let travel: CGFloat = 620
}

@MainActor
final class CapturePreview {
    static let shared = CapturePreview()
    let state = PreviewState()

    private var window: NSWindow?
    private var dismissal: Timer?
    /// Where the card sits when no gesture is moving it.
    private var restingOrigin: NSPoint?
    private var cardSize: NSSize = .zero
    private var widened = false

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

        let window = PreviewPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view)
        // Nothing is clipped or rounded here: the window is wider than the card
        // during a gesture, so the card carries its own rounded surface and
        // shadow. Clipping the host would cut the card off as it travels.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.isMovable = false
        // Follow the user across Spaces; a preview left behind on Space 1 is
        // worse than none, and it must never take focus from what they are doing.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let resting = Self.origin(for: size, on: screen)
        restingOrigin = resting
        cardSize = size
        widened = false
        state.offset = 0
        window.setFrameOrigin(resting)
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

    /// Widen the window to the right for the duration of a gesture.
    ///
    /// The card has to travel while the window stays under the pointer: a
    /// window that moves away from the cursor stops receiving the scroll events
    /// driving it, and the gesture dies halfway across. The extra width is
    /// transparent and only exists while a gesture is in progress, so it never
    /// swallows clicks meant for what is underneath.
    func beginGesture() {
        guard let window, let resting = restingOrigin, !widened else { return }
        widened = true
        window.setFrame(NSRect(x: resting.x, y: resting.y,
                               width: cardSize.width + PreviewState.travel,
                               height: cardSize.height),
                        display: false)
    }

    private func endGesture() {
        guard let window, let resting = restingOrigin, widened else { return }
        widened = false
        window.setFrame(NSRect(origin: resting, size: cardSize), display: false)
    }

    /// Follow the gesture.
    func drift(by dx: CGFloat) {
        beginGesture()
        state.offset = max(0, dx)
    }

    func settle() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { state.offset = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.endGesture()
        }
    }

    /// Send it off the right-hand edge and out of existence.
    func throwOff() {
        beginGesture()
        dismissal?.invalidate()
        dismissal = nil
        withAnimation(.easeIn(duration: 0.26)) { state.offset = PreviewState.travel }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            self?.dismiss(animated: false)
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

/// A panel that may leave the screen.
///
/// AppKit keeps windows visible by clamping their frame to the display, which
/// is why a swipe stopped dead against the right-hand edge instead of carrying
/// the card off it.
private final class PreviewPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The card itself: the capture, and the two gestures macOS's own preview has —
/// throw it to the right to dismiss, drag it anywhere else to carry the file
/// out. Click reveals it in the Finder.
private struct CapturePreviewView: View {
    let image: NSImage
    let file: URL?
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @ObservedObject var state = CapturePreview.shared.state
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

            if hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(3)
                .transition(.opacity)
            }
        }
        .padding(CapturePreview.inset)
        // A real surface behind the image, the way macOS's own preview is a
        // card rather than a bare screenshot floating on the desktop.
        .background(
            RoundedRectangle(cornerRadius: CapturePreview.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        )
        .offset(x: state.offset)
        // Fade as it goes, so a throw reads as the card leaving rather than
        // sliding under something.
        .opacity(1 - min(1, state.offset / 260) * 0.7)
        .overlay(
            GestureRouter(file: file,
                          onDrift: { CapturePreview.shared.drift(by: $0) },
                          onThrow: { CapturePreview.shared.throwOff() },
                          onSettle: { CapturePreview.shared.settle() },
                          onClick: onOpen)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

}

/// Decides, from the first few points of movement, whether the pointer is
/// throwing the card away or lifting the file out of it.
///
/// SwiftUI's `.onDrag` cannot do this: it starts a system drag session as soon
/// as the pointer moves, so there is never a moment in which to conclude that
/// the movement was a dismissal. AppKit hands over the raw events instead.
private struct GestureRouter: NSViewRepresentable {
    let file: URL?
    let onDrift: (CGFloat) -> Void
    let onThrow: () -> Void
    let onSettle: () -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> RouterView {
        let view = RouterView()
        view.file = file
        view.onDrift = onDrift
        view.onThrow = onThrow
        view.onSettle = onSettle
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: RouterView, context: Context) {
        view.file = file
    }

    final class RouterView: NSView, NSDraggingSource {
        var file: URL?
        var onDrift: ((CGFloat) -> Void)?
        var onThrow: (() -> Void)?
        var onSettle: (() -> Void)?
        var onClick: (() -> Void)?

        private enum Intent { case undecided, throwAway, carryFile }
        private var intent: Intent = .undecided
        private var start: NSPoint = .zero

        /// Past this much rightward travel the card is considered thrown.
        private static let throwDistance: CGFloat = 55
        /// Movement below this is still a click, not a gesture.
        private static let slop: CGFloat = 5

        override func mouseDown(with event: NSEvent) {
            intent = .undecided
            start = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y

            if intent == .undecided {
                guard abs(dx) > Self.slop || abs(dy) > Self.slop else { return }
                // Rightward and mostly horizontal is a throw; anything else is
                // someone taking the file somewhere.
                intent = (dx > 0 && abs(dx) > abs(dy) * 1.5) ? .throwAway : .carryFile
                if intent == .carryFile { beginFileDrag(with: event) }
            }

            if intent == .throwAway { onDrift?(max(0, dx)) }
        }

        /// A two-finger swipe on the trackpad never presses the button, so it
        /// arrives as scrolling rather than as a drag.
        private var scrollTravel: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            switch event.phase {
            case .began:
                scrollTravel = 0
            case .changed:
                // Follow the fingers: with natural scrolling, moving them right
                // gives a positive delta.
                scrollTravel += event.scrollingDeltaX
                onDrift?(max(0, scrollTravel))
            case .ended, .cancelled:
                if scrollTravel > Self.throwDistance { onThrow?() } else { onSettle?() }
                scrollTravel = 0
            default:
                break
            }
        }

        override func mouseUp(with event: NSEvent) {
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y

            switch intent {
            case .undecided:
                if abs(dx) < Self.slop && abs(dy) < Self.slop { onClick?() }
            case .throwAway:
                if dx > Self.throwDistance { onThrow?() } else { onSettle?() }
            case .carryFile:
                break   // the dragging session owns the outcome
            }
            intent = .undecided
        }

        private func beginFileDrag(with event: NSEvent) {
            guard let file else { return }
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            // Drag the card's own likeness, so what leaves looks like what was
            // grabbed rather than a generic file badge.
            let snapshot = bitmapImageRepForCachingDisplay(in: bounds)
            snapshot.map { cacheDisplay(in: bounds, to: $0) }
            if let snapshot, let cg = snapshot.cgImage {
                item.setDraggingFrame(bounds, contents: NSImage(cgImage: cg, size: bounds.size))
            } else {
                item.setDraggingFrame(bounds, contents: nil)
            }
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation {
            .copy
        }
    }
}
