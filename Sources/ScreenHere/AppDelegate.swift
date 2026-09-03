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

        offerLaunchAtLoginIfNeeded()
        offerCapturePreviewIfNeeded()
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

    /// Asked once, the first time ScreenHere runs. Declining is remembered, and
    /// the panel's switch stays available either way.
    private func offerLaunchAtLoginIfNeeded() {
        guard LoginItem.shouldOffer(hasOffered: LoginItem.hasOffered,
                                    isAlreadyEnabled: LoginItem.isEnabled) else { return }
        LoginItem.hasOffered = true

        let alert = NSAlert()
        alert.messageText = "Launch ScreenHere at login?"
        alert.informativeText = """
            ScreenHere only works while it is running. If it does not start with \
            your Mac, ⇧⌘3 will do nothing at all after a restart until you open \
            ScreenHere again.

            You can change this any time from the panel.
            """
        alert.addButton(withTitle: "Launch at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try LoginItem.setEnabled(true)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't enable Launch at Login"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    /// Asked once. macOS puts its capture preview wherever it likes, which on a
    /// multi-display Mac is rarely the screen you just captured — and it offers
    /// no setting for that. Ours can go on the right screen, but only by turning
    /// macOS's off, so the choice is the user's to make rather than ours to
    /// assume.
    private func offerCapturePreviewIfNeeded() {
        guard PreviewOffer.shouldOffer(hasOffered: PreviewOffer.hasOffered,
                                       isAlreadyOn: PreviewCoordinator.isEnabled) else { return }
        PreviewOffer.hasOffered = true

        let alert = NSAlert()
        alert.messageText = "Show the capture preview on the screen you captured?"
        alert.informativeText = """
            After a screenshot, macOS shows a small preview — on whichever display \
            it chooses, which is rarely the one you were looking at. ScreenHere can \
            show it in the corner of the screen the capture came from instead.

            This replaces macOS's preview with ScreenHere's, and switching it off \
            in the panel puts yours back exactly as it was.
            """
        alert.addButton(withTitle: "Show It There")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        UserDefaults.standard.set(true, forKey: PreviewPrefs.enabledKey)
        SystemThumbnail.suppress()
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
