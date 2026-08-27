import XCTest
@testable import ScreenHere

/// ScreenHere turns macOS's own capture preview off only while it draws its
/// own, and must put the user's setting back exactly as it found it — including
/// the common case where the key was never set at all.
final class SystemThumbnailTests: XCTestCase {

    func testAnAbsentKeyMeansMacOSShowsItsPreview() {
        XCTAssertTrue(SystemThumbnail.isEnabled(stored: nil))
        XCTAssertTrue(SystemThumbnail.isEnabled(stored: true))
        XCTAssertFalse(SystemThumbnail.isEnabled(stored: false))
    }

    /// Restoring an absent key must remove it again, not write `true`: leaving
    /// an explicit value behind changes what a later macOS default would do.
    func testRestoringAnAbsentKeyRemovesIt() {
        XCTAssertEqual(SystemThumbnail.restoreAction(original: .absent), .removeKey)
    }

    func testRestoringWritesBackWhateverWasThere() {
        XCTAssertEqual(SystemThumbnail.restoreAction(original: .value(true)), .write(true))
        XCTAssertEqual(SystemThumbnail.restoreAction(original: .value(false)), .write(false))
    }

    /// Nothing was ever suppressed, so nothing should be touched — otherwise a
    /// crash between install and first capture would rewrite a setting we never
    /// changed.
    func testRestoringWithNothingRememberedDoesNothing() {
        XCTAssertEqual(SystemThumbnail.restoreAction(original: nil), SystemThumbnail.RestoreAction.none)
    }
}
