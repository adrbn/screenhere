import AppKit

/// The menu-bar presence: an icon, a status line, the on/off toggle, a live
/// readout of which display would be captured right now, and the controls.
/// The menu is rebuilt every time it opens so the readout is never stale.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let takeover: TakeoverController

    /// Posted by a second launch (`open -n`, or reopening the .app) to ask the
    /// running instance to reveal a hidden menu-bar icon.
    static let showIconNotification = Notification.Name("com.screenhere.app.ShowMenuBar")

    private static let hideIconKey = "HideMenuBarIcon"
    /// Longest display name rendered before truncating, so the menu stays narrow.
    private static let maxNameLength = 26

    static var prefHideIcon: Bool {
        UserDefaults.standard.bool(forKey: hideIconKey)
    }

    var isIconVisible: Bool { statusItem.isVisible }

    init(takeover: TakeoverController) {
        self.takeover = takeover
        super.init()
        if let button = statusItem.button {
            button.image = MenuBarIcon.statusImage()
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        populate(menu)
        applyIconVisibility()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    // MARK: - Menu construction

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let permission = CaptureRunner.hasScreenRecordingPermission

        let status = NSMenuItem(
            title: Self.statusText(takeover.status, permissionGranted: permission),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !permission {
            let grant = NSMenuItem(title: "Grant Screen Recording Permission…",
                                   action: #selector(grantPermission), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Capture the Screen Under the Pointer",
                                action: #selector(toggleTakeover), keyEquivalent: "")
        toggle.target = self
        toggle.state = takeover.isOn ? .on : .off
        menu.addItem(toggle)

        let target = NSMenuItem(
            title: Self.targetText(
                displayName: CursorDisplay.displayName(at: CursorDisplay.cursorLocation())),
            action: nil, keyEquivalent: "")
        target.isEnabled = false
        menu.addItem(target)

        menu.addItem(.separator())

        // Always present, whatever the state — this is the user's escape hatch
        // if a crash ever left the system shortcuts disabled.
        let restore = NSMenuItem(title: "Restore macOS Shortcuts",
                                 action: #selector(restoreShortcuts), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let hideIcon = NSMenuItem(title: "Hide Menu Bar Icon",
                                  action: #selector(toggleHideIcon), keyEquivalent: "")
        hideIcon.target = self
        hideIcon.state = isIconVisible ? .off : .on
        menu.addItem(hideIcon)

        let checkUpdates = NSMenuItem(title: "Check for Updates…",
                                      action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        menu.addItem(.separator())

        let github = NSMenuItem(title: "View on GitHub",
                                action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ScreenHere", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Pure text (unit-tested)

    static func statusText(_ status: TakeoverController.Status,
                           permissionGranted: Bool) -> String {
        if !permissionGranted, status != .off {
            return "Screen Recording permission needed"
        }
        switch status {
        case .on: return "⇧⌘3 captures the screen under your pointer"
        case .off: return "Off — macOS handles ⇧⌘3"
        case .onPendingLogout: return "Log out to finish taking over ⇧⌘3"
        case .failed(let reason): return "Couldn't take over: \(reason)"
        }
    }

    static func targetText(displayName: String?) -> String {
        "Pointer is on: \(shortName(displayName ?? "unknown display"))"
    }

    /// Truncates long display names with an ellipsis so the menu stays narrow.
    static func shortName(_ name: String, max: Int = maxNameLength) -> String {
        guard name.count > max else { return name }
        return name.prefix(max - 1).trimmingCharacters(in: .whitespaces) + "…"
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

    // MARK: - Actions

    @objc private func toggleTakeover() {
        if takeover.isOn {
            takeover.disable()
        } else {
            if !CaptureRunner.hasScreenRecordingPermission {
                CaptureRunner.requestScreenRecordingPermission()
            }
            takeover.enable()
            if case .failed(let reason) = takeover.status {
                let alert = NSAlert()
                alert.messageText = "Couldn't take over ⇧⌘3"
                alert.informativeText = reason
                alert.runModal()
            }
        }
    }

    @objc private func restoreShortcuts() {
        takeover.disable()
    }

    @objc private func grantPermission() {
        // Prompts only the first time; afterwards macOS stays silent, so send
        // the user straight to the pane where the switch actually lives.
        CaptureRunner.requestScreenRecordingPermission()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleHideIcon() {
        let nowHidden = isIconVisible
        if nowHidden {
            let alert = NSAlert()
            alert.messageText = "Hide menu bar icon?"
            alert.informativeText = """
                The icon will disappear but ScreenHere keeps running, and ⇧⌘3 \
                keeps capturing the screen under your pointer. To show the icon \
                again, open ScreenHere from /Applications or Spotlight.
                """
            alert.addButton(withTitle: "Hide")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertSecondButtonReturn { return }
        }
        UserDefaults.standard.set(nowHidden, forKey: Self.hideIconKey)
        statusItem.isVisible = !nowHidden
    }

    @objc private func checkForUpdates() {
        UpdateChecker.checkInteractively()
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(UpdateChecker.repositoryURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
