import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let takeover = TakeoverController()
    private var menu: MenuBarController?
    private var didCompleteLaunch = false
    private let log = OSLog(subsystem: "com.screenhere.app", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance (e.g. `open -n`) asks the running one to reveal
        // its icon, then quits. Reopening the .app is handled below instead.
        if anotherInstanceIsRunning() {
            log("Second instance detected — forwarding show-icon request, then quitting.")
            DistributedNotificationCenter.default().postNotificationName(
                MenuBarController.showIconNotification, object: nil,
                options: [.deliverImmediately])
            NSApp.terminate(nil)
            return
        }

        // Before anything else: if a previous run died holding the system
        // shortcuts, give them back now.
        takeover.healAfterUncleanExit()

        let controller = MenuBarController(takeover: takeover)
        menu = controller
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showMenuBarIcon),
            name: MenuBarController.showIconNotification, object: nil)

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

        offerLaunchAtLoginIfNeeded()
    }

    @objc private func handlePowerOff() {
        log("System is powering off — restoring the macOS shortcuts.")
        takeover.disable()
    }

    /// Asked once, the first time ScreenHere runs. Declining is remembered, and
    /// the menu item stays available either way.
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

            You can change this any time from the menu.
            """
        alert.addButton(withTitle: "Launch at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)   // an .accessory app needs this to come forward
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

    /// The common recovery path: double-clicking the .app while it is already
    /// running activates the existing process instead of spawning a new one,
    /// so `applicationDidFinishLaunching` does not fire again.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard didCompleteLaunch else { return }
        guard let menu, !menu.isIconVisible else { return }
        log("Reopened while icon hidden — revealing for this session.")
        menu.unhideIcon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        if let menu, !menu.isIconVisible {
            log("Reopen event while icon hidden — revealing for this session.")
            menu.unhideIcon()
        }
        return true
    }

    /// Hand ⇧⌘3 back to macOS on the way out. This is the first of the four
    /// guards in the spec; the others cover the paths that never reach here.
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        takeover.disable()
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != myPID
        }
    }

    @objc private func showMenuBarIcon() {
        menu?.unhideIcon()
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
