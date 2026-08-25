import CoreGraphics
import Foundation

enum CaptureDestination: Equatable {
    /// Whatever the user configured in the Screenshot app: `-p`.
    case userSettings
    /// Forced to the clipboard, the meaning of the Control modifier: `-c`.
    case clipboard
}

/// Runs the system screenshot binary, scoped to one display.
///
/// ScreenHere deliberately does not capture pixels itself. Delegating to
/// `/usr/sbin/screencapture` inherits the user's destination, folder, file
/// format and shutter sound for free, and keeps working if they change those
/// settings later.
enum CaptureRunner {
    private static let executable = "/usr/sbin/screencapture"

    /// Verified on macOS 27.0: `-p` honours `-D`, so `-p -D2` routes a capture
    /// of display 2 through the user's configured destination.
    static func arguments(destination: CaptureDestination, displayIndex: Int) -> [String] {
        let index = max(1, displayIndex)
        switch destination {
        case .userSettings: return ["-p", "-D\(index)"]
        case .clipboard: return ["-c", "-D\(index)"]
        }
    }

    static func run(destination: CaptureDestination, displayIndex: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(destination: destination, displayIndex: displayIndex)
        try? process.run()
    }

    /// TCC attributes the `screencapture` child to ScreenHere as the
    /// responsible process, so this reflects ScreenHere's own grant.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }
}
