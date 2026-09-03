import Foundation

/// The one-time welcome.
///
/// Both of these were separate modal alerts, fired one after the other on the
/// first launch — a lot of interruption for a utility whose whole point is to
/// stay out of the way. And the alternative, leaving them switched off in the
/// panel, is exactly how the capture preview went unnoticed by the only person
/// who wanted it. So they are asked together, once, and neither is assumed.
enum FirstRun {

    /// Whether there is still something worth asking.
    static func shouldGreet(offeredLogin: Bool, offeredPreview: Bool,
                            loginIsOn: Bool, previewIsOn: Bool) -> Bool {
        let loginWorthAsking = !offeredLogin && !loginIsOn
        let previewWorthAsking = !offeredPreview && !previewIsOn
        return loginWorthAsking || previewWorthAsking
    }

    /// Pre-ticked: without it, a restart leaves ⇧⌘3 doing nothing at all,
    /// which is the worst state ScreenHere can leave a Mac in.
    static let defaultLoginChoice = true

    /// Not pre-ticked: it turns off a macOS setting that belongs to the user.
    static let defaultPreviewChoice = false
}
