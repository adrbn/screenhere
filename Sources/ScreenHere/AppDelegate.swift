import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let takeover = TakeoverController.shared
    private var didCompleteLaunch = false
    private let log = OSLog(subsystem: "com.screenhere.app", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance (e.g. `open -n`) asks the running one to reveal
        // its icon, then quits. Reopening the .app is handled below instead.
        if anotherInstanceIsRunning() {
            log("Second instance detected — forwarding show-icon request, then quitting.")
            DistributedNotificationCenter.default().postNotificationName(
                Self.showIconNotification, object: nil, options: [.deliverImmediately])
            NSApp.terminate(nil)
            return
        }

        // Before anything else: if a previous run died holding the system
        // shortcuts, give them back now.
        takeover.healAfterUncleanExit()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showMenuBarIcon),
            name: Self.showIconNotification, object: nil)

        // Logout and shutdown do not reliably reach applicationWillTerminate,
        // and a machine that reboots without ScreenHere is left in the worst of
        // both worlds: the system entries are still disabled in preferences and
        // nothing is holding the combination, so ⇧⌘3 does nothing at all rather
        // than falling back to stock macOS. Give the shortcuts back here.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handlePowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil)

        takeover.enable()
        if case .failed(let reason) = takeover.status {
            log("Takeover failed at launch: \(reason)")
        }
        didCompleteLaunch = true

        if PreviewCoordinator.isEnabled { CaptureWatcher.shared.start() }

        greetIfNeeded()
    }

    /// Posted by a second launch to ask the running instance to reveal a
    /// hidden menu-bar icon.
    static let showIconNotification = Notification.Name("com.screenhere.app.ShowMenuBar")

    /// The common recovery path: double-clicking the .app while it is already
    /// running activates the existing process instead of spawning a new one,
    /// so `applicationDidFinishLaunching` does not fire again.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard didCompleteLaunch else { return }
        revealIcon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        revealIcon()
        return true
    }

    @objc private func showMenuBarIcon() {
        revealIcon()
    }

    /// Opening the app again is the documented way back from a hidden icon, so
    /// it clears the preference outright rather than only for this session.
    private func revealIcon() {
        guard UserDefaults.standard.bool(forKey: MenuBarPrefs.hideIconKey) else { return }
        log("Reopened while the icon was hidden — revealing it.")
        UserDefaults.standard.set(false, forKey: MenuBarPrefs.hideIconKey)
    }

    @objc private func handlePowerOff() {
        log("System is powering off — restoring the macOS shortcuts.")
        takeover.disable()
        SystemThumbnail.restore()
    }

    /// Asked once, together. Both of these used to be separate modal alerts
    /// fired back to back, which is a lot of interruption for a utility whose
    /// point is staying out of the way — and leaving them switched off in the
    /// panel instead is exactly how the capture preview went unnoticed by the
    /// person who wanted it.
    private func greetIfNeeded() {
        let offeredLogin = LoginItem.hasOffered
        let offeredPreview = PreviewOffer.hasOffered
        guard FirstRun.shouldGreet(offeredLogin: offeredLogin,
                                   offeredPreview: offeredPreview,
                                   loginIsOn: LoginItem.isEnabled,
                                   previewIsOn: PreviewCoordinator.isEnabled) else { return }

        let login = NSButton(checkboxWithTitle: "Launch ScreenHere at login", target: nil, action: nil)
        login.state = FirstRun.defaultLoginChoice ? .on : .off
        login.toolTip = "Without this, ⇧⌘3 does nothing at all after a restart "
            + "until you open ScreenHere again."

        let preview = NSButton(checkboxWithTitle: "Show the capture preview on the screen you captured",
                               target: nil, action: nil)
        preview.state = FirstRun.defaultPreviewChoice ? .on : .off
        preview.toolTip = "Replaces macOS's own preview, which appears on whichever "
            + "display it chooses. Switching it off puts yours back."

        let stack = NSStackView(views: [login, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 46)

        // An .accessory app owns no Dock tile and is never frontmost on its own,
        // so a modal it puts up opens *behind* everything — the first attempt
        // at this greeting recorded itself as answered without ever being seen.
        // Promote for the duration, exactly as the updater does for Sparkle's
        // window, then drop back to being invisible.
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }

        let alert = NSAlert()
        alert.messageText = "ScreenHere is running"
        alert.informativeText = """
            ⇧⌘3 now captures the screen your pointer is on. Nothing else changes: \
            your screenshots go where they always did.

            Two things you can turn on, and change any time from the menu:
            """
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue")
        alert.runModal()

        // Recorded only once it has actually been answered, so a greeting that
        // fails to appear is not silently spent.
        LoginItem.hasOffered = true
        PreviewOffer.hasOffered = true

        if login.state == .on, !LoginItem.isEnabled {
            do {
                try LoginItem.setEnabled(true)
            } catch {
                let failure = NSAlert()
                failure.messageText = "Couldn't enable Launch at Login"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
        if preview.state == .on {
            UserDefaults.standard.set(true, forKey: PreviewPrefs.enabledKey)
            SystemThumbnail.suppress()
        }
    }

    /// Hand ⇧⌘3 back to macOS on the way out.
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        takeover.disable()
        // The capture preview is a change to the user's own settings; it goes
        // back whenever ScreenHere is not running to justify it.
        SystemThumbnail.restore()
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != myPID
        }
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
