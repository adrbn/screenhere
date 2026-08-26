import Foundation

/// Preference keys shared by the scene and the delegate: the scene binds the
/// menu-bar item's presence to this, and reopening the app clears it.
enum MenuBarPrefs {
    static let hideIconKey = "HideMenuBarIcon"
}
