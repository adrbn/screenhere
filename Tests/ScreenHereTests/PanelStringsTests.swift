import XCTest
@testable import ScreenHere

/// Only the panel's wording is unit-tested; the SwiftUI layout is judged by eye.
final class PanelStringsTests: XCTestCase {

    func testHeadlineFollowsTheShortcutChip() {
        XCTAssertEqual(PanelStrings.headline(isOn: true),
                       "captures the screen under your pointer")
        XCTAssertEqual(PanelStrings.headline(isOn: false), "is handled by macOS")
    }

    func testNothingIsReportedWhenAllIsWell() {
        XCTAssertNil(PanelStrings.problem(status: .on, permissionGranted: true))
        XCTAssertNil(PanelStrings.problem(status: .off, permissionGranted: true))
    }

    /// A missing permission is more urgent than the takeover state — without it
    /// every capture silently produces nothing.
    func testMissingPermissionOutranksTheOnStatus() {
        XCTAssertEqual(PanelStrings.problem(status: .on, permissionGranted: false),
                       "Screen Recording permission needed")
    }

    /// But it is not worth mentioning while ScreenHere is not capturing at all.
    func testMissingPermissionIsSilentWhileOff() {
        XCTAssertNil(PanelStrings.problem(status: .off, permissionGranted: false))
    }

    /// The failure that looked like "the app does nothing": macOS never let go
    /// of ⇧⌘3, so every press captured every display on top of our one.
    func testADoubleHandledShortcutIsCalledOut() {
        XCTAssertEqual(
            PanelStrings.problem(status: .on, permissionGranted: true,
                                 systemStillHandlesShortcut: true),
            "macOS is still handling ⇧⌘3 — log out and back in")
    }

    /// Not worth saying while ScreenHere is deliberately off: macOS handling
    /// ⇧⌘3 is the whole point then.
    func testADoubleHandledShortcutIsSilentWhileOff() {
        XCTAssertNil(PanelStrings.problem(status: .off, permissionGranted: true,
                                          systemStillHandlesShortcut: true))
    }

    func testPendingLogoutTellsTheUserWhatToDo() {
        XCTAssertEqual(PanelStrings.problem(status: .onPendingLogout, permissionGranted: true),
                       "Log out to finish taking over ⇧⌘3")
    }

    func testFailureSurfacesTheReason() {
        XCTAssertEqual(
            PanelStrings.problem(status: .failed("Another app is already holding ⇧⌘3."),
                                 permissionGranted: true),
            "Another app is already holding ⇧⌘3.")
    }

    func testLongDisplayNamesAreTruncated() {
        let short = PanelStrings.shortName("LG UltraFine 5K Display (Thunderbolt 3)")
        XCTAssertLessThanOrEqual(short.count, 26)
        XCTAssertTrue(short.hasSuffix("…"))
    }

    func testShortDisplayNamesArePreserved() {
        XCTAssertEqual(PanelStrings.shortName("MSI MD271UL"), "MSI MD271UL")
    }
}
