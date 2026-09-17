import AppKit
import SwiftUI

/// ⇧⌘8: the clipboard history as a floating list on the screen under the
/// pointer. Type to filter, arrows to choose, Return to copy, Escape to close.
///
/// A non-activating panel: it takes the keyboard without activating
/// ScreenHere, so the app the user was in stays frontmost and ⌘V pastes there
/// the moment the list closes.
@MainActor
final class HistoryPicker: NSObject, NSWindowDelegate {
    static let shared = HistoryPicker()

    private var panel: NSPanel?
    private static let size = NSSize(width: 540, height: 420)

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        close()
        let model = HistoryPickerModel(clipboard: .shared)
        model.onChoose = { [weak self] item in
            let copied = ClipboardController.shared.copy(item)
            self?.close()
            if copied {
                Toast.show("Copied — paste with ⌘V", systemImage: "doc.on.clipboard")
            } else {
                Toast.show("That image is no longer on this Mac", systemImage: "exclamationmark.triangle")
            }
        }
        model.onClose = { [weak self] in self?.close() }
        model.onClear = { ClipboardController.shared.clear() }

        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.contentView = FixedHosting.view(HistoryPickerView(model: model, clipboard: .shared, links: .shared), size: Self.size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let screen = PreviewCoordinator.screenUnderPointer() ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // Upper-middle, where Spotlight sits: the eye goes there first.
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                         y: frame.minY + frame.height * 0.62 - Self.size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Clicking anywhere else dismisses it, like any transient chooser.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class HistoryPickerModel: ObservableObject {
    @Published var query = "" {
        didSet { selection = 0 }
    }
    @Published var selection = 0
    /// The footer is asking whether to clear everything.
    @Published private(set) var confirmingClear = false

    let clipboard: ClipboardController
    var onChoose: (ClipItem) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onClear: () -> Void = {}

    init(clipboard: ClipboardController) {
        self.clipboard = clipboard
    }

    var results: [ClipItem] { clipboard.history.matching(query) }

    func move(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// Return copies — and never confirms clearing everything.
    func submit() {
        guard !confirmingClear else { return }
        chooseSelection()
    }

    /// Escape backs out of the question first, then closes the list.
    func cancel() {
        if confirmingClear {
            confirmingClear = false
        } else {
            onClose()
        }
    }

    func askToClear() {
        confirmingClear = true
    }

    func clearAll() {
        confirmingClear = false
        onClear()
        selection = 0
    }

    func chooseSelection() {
        let results = self.results
        guard results.indices.contains(selection) else { return }
        onChoose(results[selection])
    }

    func remove(_ item: ClipItem) {
        clipboard.remove(item)
        selection = min(selection, max(results.count - 1, 0))
    }
}
