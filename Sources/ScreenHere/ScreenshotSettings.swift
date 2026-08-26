import Foundation

/// Reads where macOS is sending screenshots, from the same `com.apple.screencapture`
/// preferences `screencapture -p` obeys — so the panel reports what will really
/// happen rather than what ScreenHere assumes.
enum ScreenshotSettings {
    private static let domain = "com.apple.screencapture"

    /// A short human label for the current destination.
    static var current: String {
        let defaults = UserDefaults(suiteName: domain)
        return describe(target: defaults?.string(forKey: "target-screenshot"),
                        location: defaults?.string(forKey: "location"))
    }

    /// Pure. `target` is macOS's `target-screenshot`; `location` its `location`.
    static func describe(target: String?, location: String?) -> String {
        switch target?.lowercased() {
        case "clipboard":
            return "Clipboard"
        case "file", .none:
            guard let location, !location.isEmpty else { return "Desktop" }
            let name = (location as NSString).expandingTildeInPath
            let folder = URL(fileURLWithPath: name).lastPathComponent
            return folder.isEmpty ? "Desktop" : folder
        case .some(let other):
            // Preview, Mail, Messages… report it rather than guess a folder.
            return other.prefix(1).uppercased() + other.dropFirst()
        }
    }
}
