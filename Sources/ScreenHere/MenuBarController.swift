import AppKit
import SwiftUI

/// The menu-bar presence: an icon that opens a panel rather than a plain menu.
///
/// An `NSMenu` cannot draw the live display map, which is the one thing worth
/// showing here — so the status item hosts an `NSPopover` with a SwiftUI view.
/// The status item itself stays AppKit: hiding and revealing the icon is a
/// property on it, and the takeover logic must not depend on the UI framework.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let takeover: TakeoverController
    private let model: PanelModel
    private let popover = NSPopover()

    /// Posted by a second launch (`open -n`, or reopening the .app) to ask the
    /// running instance to reveal a hidden menu-bar icon.
    static let showIconNotification = Notification.Name("com.screenhere.app.ShowMenuBar")

    private static let hideIconKey = "HideMenuBarIcon"

    static var prefHideIcon: Bool {
        UserDefaults.standard.bool(forKey: hideIconKey)
    }

    var isIconVisible: Bool { statusItem.isVisible }

    init(takeover: TakeoverController) {
        self.takeover = takeover
        self.model = PanelModel(takeover: takeover)
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarIcon.statusImage()
            button.action = #selector(togglePanel)
            button.target = self
        }

        popover.behavior = .transient      // click anywhere else to dismiss
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(
            model: model,
            onRestoreShortcuts: { [weak self] in self?.restoreShortcuts() },
            onHideIcon: { [weak self] in self?.hideIcon() },
            onCheckUpdates: { UpdateChecker.checkInteractively() },
            onOpenGitHub: { NSWorkspace.shared.open(UpdateChecker.repositoryURL) },
            onQuit: { NSApp.terminate(nil) }))

        applyIconVisibility()
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An .accessory app does not become active on its own, and without this
        // the panel opens behind the frontmost window's key state.
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.stopPolling()
    }

    // MARK: - Icon visibility

    private func applyIconVisibility() {
        statusItem.isVisible = !Self.prefHideIcon
    }

    /// Reveals the icon for this session without changing the persisted
    /// preference, so reopening the .app is a way back from a hidden icon.
    func unhideIcon() {
        statusItem.isVisible = true
    }

    private func hideIcon() {
        popover.performClose(nil)

        let alert = NSAlert()
        alert.messageText = "Hide menu bar icon?"
        alert.informativeText = """
            The icon will disappear but ScreenHere keeps running, and ⇧⌘3 keeps \
            capturing the screen under your pointer. To show the icon again, open \
            ScreenHere from /Applications or Spotlight.
            """
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        UserDefaults.standard.set(true, forKey: Self.hideIconKey)
        statusItem.isVisible = false
    }

    private func restoreShortcuts() {
        popover.performClose(nil)
        takeover.disable()
        model.refresh()
    }
}
