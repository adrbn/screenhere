import AppKit
import SwiftUI

/// Hands a SwiftUI view the NSWindow it ends up in.
///
/// MenuBarExtra gives its content no lifecycle worth trusting — no
/// onDisappear on close — so the panel reports its window and lets the
/// window's own occlusion state say when it is really on screen.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {}

    final class ReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Deferred: the window is still being assembled at this point.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.onWindow?(window)
            }
        }
    }
}
