import Foundation
import ServiceManagement

/// Wraps SMAppService (macOS 13+). Note: reliable registration requires a
/// signed, installed .app; unsigned dev builds may report `.notRegistered`
/// or throw — the caller surfaces the error.
enum LoginItem {
    private static let offeredKey = "DidOfferLaunchAtLogin"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Whether the one-time "launch at login?" offer is still owed.
    ///
    /// This matters more here than in a typical menu-bar app. ScreenHere only
    /// works while it runs, and it leaves the system shortcut disabled in
    /// preferences while it holds it. So a Mac that restarts without ScreenHere
    /// as a login item lands in the worst of both worlds: macOS is not handling
    /// ⇧⌘3 and neither is ScreenHere, so the key does nothing at all instead of
    /// falling back to stock behaviour.
    static func shouldOffer(hasOffered: Bool, isAlreadyEnabled: Bool) -> Bool {
        !hasOffered && !isAlreadyEnabled
    }

    static var hasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }
}
