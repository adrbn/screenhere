import Carbon.HIToolbox
import XCTest
@testable import ScreenHere

/// Carbon and the symbolic-hotkey plist describe the same key combination with
/// two different modifier encodings. If they ever disagree, ScreenHere would
/// disable one shortcut and register a different one — so the correspondence
/// is pinned by tests rather than by eyeballing.
final class HotkeyRegistrarTests: XCTestCase {

    func testBothCombosUseTheNumberThreeKey() {
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.keyCode, UInt32(kVK_ANSI_3))
        XCTAssertEqual(HotkeyCombo.screenshotToClipboard.keyCode, UInt32(kVK_ANSI_3))
        // 20 is the value macOS stores in the symbolic-hotkey parameters array.
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.keyCode, 20)
    }

    func testShiftCommandMatchesSymbolicHotkey28() {
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.cocoaModifierMask, 1_179_648)
    }

    func testControlShiftCommandMatchesSymbolicHotkey29() {
        XCTAssertEqual(HotkeyCombo.screenshotToClipboard.cocoaModifierMask, 1_441_792)
    }

    func testCombosHaveDistinctIdentifiers() {
        XCTAssertNotEqual(HotkeyCombo.screenshotToDestination.id,
                          HotkeyCombo.screenshotToClipboard.id)
    }

    func testCarbonModifiersAreTheCarbonConstants() {
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.carbonModifiers,
                       UInt32(shiftKey | cmdKey))
        XCTAssertEqual(HotkeyCombo.screenshotToClipboard.carbonModifiers,
                       UInt32(shiftKey | cmdKey | controlKey))
    }
}
