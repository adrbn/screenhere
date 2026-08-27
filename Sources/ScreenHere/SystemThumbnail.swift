import Foundation

/// macOS's own capture preview — the small image that slides into a corner
/// after a screenshot.
///
/// ScreenHere can draw its own on the display that was captured, which macOS
/// offers no way to do. Two previews would be absurd, so turning ours on turns
/// macOS's off — and that is a change to the user's own settings, which this
/// app otherwise never makes. Hence: opt-in, and put back exactly what was
/// there, including the very common case of a key that was never set.
enum SystemThumbnail {
    static let domain = "com.apple.screencapture"
    static let key = "show-thumbnail"

    /// What we found before suppressing it. `.absent` is not the same as
    /// `.value(true)`: writing `true` back would leave an explicit setting
    /// where the user had none.
    enum Original: Equatable {
        case absent
        case value(Bool)
    }

    enum RestoreAction: Equatable {
        case none
        case removeKey
        case write(Bool)
    }

    /// macOS shows the preview unless told otherwise.
    static func isEnabled(stored: Bool?) -> Bool { stored ?? true }

    /// What putting things back should do. `original` is nil when we never
    /// suppressed anything — a crash between install and the first capture must
    /// not rewrite a setting we never touched.
    static func restoreAction(original: Original?) -> RestoreAction {
        switch original {
        case .none: return .none
        case .absent: return .removeKey
        case .value(let wasOn): return .write(wasOn)
        }
    }

    // MARK: - Live preferences

    private static let rememberedKey = "OriginalShowThumbnail"
    private static let rememberedAbsent = "OriginalShowThumbnailWasAbsent"

    static var current: Bool {
        isEnabled(stored: UserDefaults(suiteName: domain)?.object(forKey: key) as? Bool)
    }

    static var remembered: Original? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: rememberedAbsent) { return .absent }
        guard let value = defaults.object(forKey: rememberedKey) as? Bool else { return nil }
        return .value(value)
    }

    /// Remember what is there, then turn macOS's preview off.
    static func suppress() {
        guard remembered == nil else { return }   // already ours; do not re-remember
        let stored = UserDefaults(suiteName: domain)?.object(forKey: key) as? Bool
        if let stored {
            UserDefaults.standard.set(stored, forKey: rememberedKey)
        } else {
            UserDefaults.standard.set(true, forKey: rememberedAbsent)
        }
        write(false)
    }

    /// Put the user's setting back exactly as it was.
    static func restore() {
        switch restoreAction(original: remembered) {
        case .none: return
        case .removeKey: run(["delete", domain, key])
        case .write(let value): write(value)
        }
        UserDefaults.standard.removeObject(forKey: rememberedKey)
        UserDefaults.standard.removeObject(forKey: rememberedAbsent)
    }

    private static func write(_ value: Bool) {
        run(["write", domain, key, "-bool", value ? "true" : "false"])
    }

    /// Through `defaults` rather than CFPreferences: this domain is read by the
    /// system's own capture UI, and cfprefsd can serve a stale in-process cache.
    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
