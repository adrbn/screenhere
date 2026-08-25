import XCTest
@testable import ScreenHere

final class CaptureRunnerTests: XCTestCase {

    /// `-p` makes screencapture reuse the user's own macOS screenshot
    /// settings — destination, folder, format, sound — so ⇧⌘3 keeps behaving
    /// exactly as they configured it, only on the right display.
    func testDefaultDestinationDefersToTheUsersSettings() {
        XCTAssertEqual(CaptureRunner.arguments(destination: .userSettings, displayIndex: 2),
                       ["-p", "-D2"])
    }

    /// ⌃⇧⌘3 means "to the clipboard" in macOS regardless of settings.
    func testClipboardDestinationForcesTheClipboard() {
        XCTAssertEqual(CaptureRunner.arguments(destination: .clipboard, displayIndex: 1),
                       ["-c", "-D1"])
    }

    func testDisplayIndexIsInterpolatedWithoutASpace() {
        // `screencapture` parses -D as an attached-argument flag; "-D 2" fails.
        let arguments = CaptureRunner.arguments(destination: .userSettings, displayIndex: 3)
        XCTAssertTrue(arguments.contains("-D3"))
        XCTAssertFalse(arguments.contains("-D"))
    }

    /// CursorDisplay never returns less than 1, but a clamped floor here means
    /// a future caller cannot produce "-D0" and silently capture nothing.
    func testIndexIsClampedToAValidDisplay() {
        XCTAssertEqual(CaptureRunner.arguments(destination: .clipboard, displayIndex: 0),
                       ["-c", "-D1"])
        XCTAssertEqual(CaptureRunner.arguments(destination: .clipboard, displayIndex: -7),
                       ["-c", "-D1"])
    }
}
