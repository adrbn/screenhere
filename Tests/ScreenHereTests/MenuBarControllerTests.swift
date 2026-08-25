import XCTest
@testable import ScreenHere

/// Only the pure status-line logic is unit-tested; the AppKit menu wiring is
/// exercised by hand in the end-to-end run.
final class MenuBarControllerTests: XCTestCase {

    func testOnStatusNamesTheShortcutItHolds() {
        XCTAssertEqual(MenuBarController.statusText(.on, permissionGranted: true),
                       "⇧⌘3 captures the screen under your pointer")
    }

    func testOffStatusSaysMacOSIsBackInCharge() {
        XCTAssertEqual(MenuBarController.statusText(.off, permissionGranted: true),
                       "Off — macOS handles ⇧⌘3")
    }

    func testPendingLogoutStatusTellsTheUserWhatToDo() {
        XCTAssertEqual(MenuBarController.statusText(.onPendingLogout, permissionGranted: true),
                       "Log out to finish taking over ⇧⌘3")
    }

    /// A missing permission is more urgent than the takeover state — without
    /// it every capture silently produces nothing.
    func testMissingScreenRecordingPermissionOutranksTheOnStatus() {
        XCTAssertEqual(MenuBarController.statusText(.on, permissionGranted: false),
                       "Screen Recording permission needed")
    }

    func testFailedStatusSurfacesTheReason() {
        XCTAssertEqual(
            MenuBarController.statusText(.failed("Another app is already holding ⇧⌘3."),
                                         permissionGranted: true),
            "Couldn't take over: Another app is already holding ⇧⌘3.")
    }

    func testTargetLineNamesTheDisplayUnderThePointer() {
        XCTAssertEqual(MenuBarController.targetText(displayName: "Built-in Retina Display"),
                       "Pointer is on: Built-in Retina Display")
    }

    func testTargetLineDegradesWhenTheDisplayCannotBeNamed() {
        XCTAssertEqual(MenuBarController.targetText(displayName: nil),
                       "Pointer is on: unknown display")
    }

    func testLongDisplayNamesAreTruncated() {
        let short = MenuBarController.shortName("LG UltraFine 5K Display (Thunderbolt 3)")
        XCTAssertLessThanOrEqual(short.count, 26)
        XCTAssertTrue(short.hasSuffix("…"))
    }

    func testShortDisplayNamesArePreserved() {
        XCTAssertEqual(MenuBarController.shortName("MSI MD271UL"), "MSI MD271UL")
    }
}
