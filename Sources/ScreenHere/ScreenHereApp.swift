import SwiftUI

@main
struct ScreenHereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PanelModel(takeover: .shared)

    /// Persisted so a hidden icon stays hidden across launches. Reopening the
    /// app from /Applications clears it — that is the way back.
    @AppStorage(MenuBarPrefs.hideIconKey) private var hideIcon = false

    var body: some Scene {
        // `.window`, not `.menu`: the live display map is the point of this
        // panel, and an NSMenu cannot draw it. An NSPopover anchored to the
        // status item cannot either — on macOS 27 the item reports a frame
        // 200pt off, pinned to the screen edge, so the panel opened nowhere
        // near the icon. MenuBarExtra is positioned by the system and lands
        // under the icon every time.
        MenuBarExtra(isInserted: Binding(get: { !hideIcon },
                                         set: { hideIcon = !$0 })) {
            PanelView(
                model: model,
                onRestoreShortcuts: {
                    TakeoverController.shared.disable()
                    model.refresh()
                },
                onHideIcon: { hideIcon = confirmHidingIcon() },
                onCheckUpdates: { UpdateChecker.checkInteractively() },
                onOpenGitHub: { NSWorkspace.shared.open(UpdateChecker.repositoryURL) },
                onQuit: { NSApp.terminate(nil) })
        } label: {
            Image(nsImage: MenuBarIcon.statusImage())
        }
        .menuBarExtraStyle(.window)
    }

    /// Once hidden, the panel is unreachable until the app is opened again, so
    /// the click is confirmed rather than taken at face value.
    private func confirmHidingIcon() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hide menu bar icon?"
        alert.informativeText = """
            The icon will disappear but ScreenHere keeps running, and ⇧⌘3 keeps \
            capturing the screen under your pointer. To show it again, open \
            ScreenHere from /Applications or Spotlight.
            """
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
