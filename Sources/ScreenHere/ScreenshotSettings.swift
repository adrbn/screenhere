import Foundation

/// Reads where macOS is sending screenshots, from the same `com.apple.screencapture`
/// preferences `screencapture -p` obeys — so the panel reports what will really
/// happen rather than what ScreenHere assumes.
enum ScreenshotSettings {
    private static let domain = "com.apple.screencapture"

    /// The system's capture preferences. Held rather than rebuilt: constructing
    /// a suite is an XPC round trip, and reading these on a timer made that the
    /// app's single largest cost.
    static let defaults = UserDefaults(suiteName: domain)

    /// A short human label for the current destination.
    static var current: String {
        describe(target: defaults?.string(forKey: "target-screenshot"),
                 location: defaults?.string(forKey: "location"))
    }

    /// Where captures are written when the destination is a file.
    static var destinationFolder: URL {
        let path = defaults?.string(forKey: "location") ?? "~/Desktop"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static var goesToClipboard: Bool {
        defaults?.string(forKey: "target-screenshot")?.lowercased() == "clipboard"
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
