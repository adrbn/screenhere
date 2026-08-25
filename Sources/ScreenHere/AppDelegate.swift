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

        takeover.enable()
        if case .failed(let reason) = takeover.status {
            log("Takeover failed at launch: \(reason)")
        }
        didCompleteLaunch = true
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
