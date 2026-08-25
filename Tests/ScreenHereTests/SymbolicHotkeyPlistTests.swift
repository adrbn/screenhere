import XCTest
@testable import ScreenHere

final class SymbolicHotkeyPlistTests: XCTestCase {

    /// The real macOS entry for ⇧⌘3, read from com.apple.symbolichotkeys.
    /// 51 = ASCII "3", 20 = kVK_ANSI_3, 1179648 = shift + command.
    private func shk28() -> [String: Any] {
        [
            "enabled": true,
            "value": [
                "type": "standard",
                "parameters": [51, 20, 1179648],
            ] as [String: Any],
        ]
    }

    func testReadsTheEnabledFlag() {
        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(shk28()))
        XCTAssertFalse(SymbolicHotkeyPlist.isEnabled(SymbolicHotkeyPlist.disabled(shk28())))
    }

    func testMissingEnabledFlagCountsAsDisabled() {
        XCTAssertFalse(SymbolicHotkeyPlist.isEnabled(["value": ["type": "standard"]]))
    }

    /// The whole point of the app's restore path: disabling must not eat the
    /// parameters array, or the shortcut stays dead even after we re-enable it.
    func testDisablingPreservesEverythingElseVerbatim() {
        let disabled = SymbolicHotkeyPlist.disabled(shk28())
        let value = disabled["value"] as? [String: Any]
        XCTAssertEqual(value?["type"] as? String, "standard")
        XCTAssertEqual(value?["parameters"] as? [Int], [51, 20, 1179648])
    }

    func testDisablingDoesNotMutateTheOriginal() {
        let original = shk28()
        _ = SymbolicHotkeyPlist.disabled(original)
        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(original))
    }

    func testXMLRoundTripIsLossless() throws {
        let original = shk28()
        let restored = try SymbolicHotkeyPlist.entry(fromXML: SymbolicHotkeyPlist.xml(from: original))
        XCTAssertEqual(NSDictionary(dictionary: restored), NSDictionary(dictionary: original))
    }

    func testXMLIsAcceptableToDefaultsWrite() throws {
        let xml = try SymbolicHotkeyPlist.xml(from: SymbolicHotkeyPlist.disabled(shk28()))
        XCTAssertTrue(xml.contains("<key>enabled</key>"))
        XCTAssertTrue(xml.contains("<false/>"))
        XCTAssertTrue(xml.contains("<integer>1179648</integer>"))
    }

    func testMalformedXMLThrowsRatherThanReturningAnEmptyEntry() {
        XCTAssertThrowsError(try SymbolicHotkeyPlist.entry(fromXML: "not a plist"))
    }
}
