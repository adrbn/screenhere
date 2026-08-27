import AppKit
import Combine
import Sparkle

/// Owns Sparkle's updater and publishes what it finds.
///
/// Everything the user sees during an actual update — the prompt, the
/// changelog, "Install and Relaunch", the daily background check — is Sparkle's
/// standard driver, unchanged. What this adds is knowing quietly whether an
/// update exists, so the panel can say so instead of offering a row that only
/// reveals the answer once you press it.
///
/// Authenticity is the EdDSA `SUPublicEDKey` in Info.plist, plus Sparkle's own
/// rule that an update must satisfy the installed copy's designated
/// requirement — which is why ScreenHere has to stay Developer ID signed. An
/// ad-hoc build can never update itself: its requirement is its own cdhash.
@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Sparkle expects one updater per process.
    static let shared = UpdaterController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        // One silent check shortly after launch so the panel can show a badge,
        // delayed so it never competes with the window server settling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkQuietly()
        }
    }

    /// Ask the feed without showing anything.
    func checkQuietly() {
        guard canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
    }

    /// Manual check — shows Sparkle's UI even when already up to date, and is
    /// how an offered update actually gets installed.
    func checkForUpdates() {
        comeToFront()
        controller.updater.checkForUpdates()
    }

    /// ScreenHere is an `LSUIElement` agent, so it owns no Dock tile and is
    /// never the active app on its own. Sparkle's update window is an ordinary
    /// window: shown by a background app it opens *behind* everything, and
    /// since the flow is modal every click elsewhere just beeps — an invisible
    /// dialog holding the app hostage. Promote and activate first.
    private func comeToFront() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }

    /// Sparkle is about to replace the app and relaunch it. ScreenHere is
    /// holding ⇧⌘3 at this point, and the copy that comes back is a different
    /// process: hand the shortcut to macOS now, exactly as on quit, so the
    /// window between the two never leaves a dead key.
    nonisolated func updater(_ updater: SPUUpdater,
                             willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        Task { @MainActor in TakeoverController.shared.disable() }
        return false
    }

    /// Current app version, for the panel.
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static let repositoryURL = URL(string: "https://github.com/adrbn/screenhere")!
}

// MARK: - Gentle reminders
//
// Sparkle warns that a background app scheduling its own checks "does not
// implement gentle reminders", and it is right: left alone it either pops a
// window the user never asked for or, for an agent, one they cannot see.
// ScreenHere announces an available update in its own panel, so scheduled finds
// are handled there and Sparkle only takes the screen when the user asked.
extension UpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            self.availableVersion = update.displayVersionString
            if state.userInitiated { self.comeToFront() }
        }
    }
}
