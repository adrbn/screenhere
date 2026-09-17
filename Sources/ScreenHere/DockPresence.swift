import AppKit

/// ScreenHere lives in the menu bar, with no Dock tile, and so is never the
/// active app on its own: a window it opens lands *behind* everything, and a
/// modal one then makes every click elsewhere beep. Before such a window, it
/// takes a Dock tile and activates; once the window is gone, it gives the tile
/// back so it does not stay in the Dock for good.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private let policy: () -> NSApplication.ActivationPolicy
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void
    /// Where to step back to, while a window of ours needs the tile.
    private var original: NSApplication.ActivationPolicy?
    /// How many of our windows need it. An update can be checked from the menu
    /// while the greeting is still up: the tile goes when the last one is gone.
    private var holders = 0

    init(policy: @escaping () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() },
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) },
         activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.policy = policy
        self.setPolicy = setPolicy
        self.activate = activate
    }

    func comeToFront() {
        if holders == 0 { original = policy() }
        holders += 1
        if policy() != .regular { setPolicy(.regular) }
        activate()
    }

    func stepBack() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, let original else { return }
        self.original = nil
        setPolicy(original)
    }
}
