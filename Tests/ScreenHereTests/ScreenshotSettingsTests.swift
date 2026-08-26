import XCTest
@testable import ScreenHere

/// The panel tells the user where their captures are going, read from the same
/// macOS preferences `screencapture -p` obeys. Getting this wrong would be
/// worse than saying nothing, so the parsing is pinned.
final class ScreenshotSettingsTests: XCTestCase {

    func testClipboardTarget() {
        XCTAssertEqual(ScreenshotSettings.describe(target: "clipboard", location: "~/Desktop"),
                       "Clipboard")
    }

    /// macOS writes to the Desktop when no location has been chosen.
    func testFileTargetWithNoLocationFallsBackToDesktop() {
        XCTAssertEqual(ScreenshotSettings.describe(target: "file", location: nil), "Desktop")
        XCTAssertEqual(ScreenshotSettings.describe(target: nil, location: nil), "Desktop")
    }

    func testFileTargetNamesTheFolder() {
        XCTAssertEqual(ScreenshotSettings.describe(target: "file", location: "~/Pictures/Shots"),
                       "Shots")
        XCTAssertEqual(ScreenshotSettings.describe(target: "file", location: "/Users/x/Captures/"),
                       "Captures")
    }

    func testUnknownTargetIsReportedRatherThanGuessed() {
        XCTAssertEqual(ScreenshotSettings.describe(target: "preview", location: nil), "Preview")
    }
}
