import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ScreenHere

final class KeyShortcutTests: XCTestCase {
    private func shortcut(_ keyCode: Int, _ modifiers: Int) -> KeyShortcut {
        KeyShortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
    }

    // MARK: - Labels

    func testModifiersComeInMacOSOrder() {
        let label = shortcut(kVK_ANSI_W, cmdKey | shiftKey | optionKey)
            .label(typed: { _, _ in "w" })
        XCTAssertEqual(label, "⌥⇧⌘W")
    }

    func testTheDefaultReadsShiftCommand2OnAnAmericanKeyboard() {
        let american: (UInt32, Bool) -> String? = { _, shift in shift ? "@" : "2" }
        XCTAssertEqual(KeyShortcut.shiftCommand2.label(typed: american), "⇧⌘2")
    }

    /// On a French keyboard the key types é, and 2 with ⇧: the digit is what
    /// is printed on the key and what people call the shortcut.
    func testTheDigitWinsOnAFrenchKeyboard() {
        let french: (UInt32, Bool) -> String? = { _, shift in shift ? "2" : "é" }
        XCTAssertEqual(KeyShortcut.shiftCommand2.label(typed: french), "⇧⌘2")
    }

    func testKeysThatTypeNothingHaveNames() {
        let none: (UInt32, Bool) -> String? = { _, _ in nil }
        XCTAssertEqual(shortcut(kVK_F5, optionKey).label(typed: none), "⌥F5")
        XCTAssertEqual(shortcut(kVK_Space, cmdKey | optionKey).label(typed: none), "⌥⌘Space")
        XCTAssertEqual(shortcut(kVK_LeftArrow, cmdKey).label(typed: none), "⌘←")
    }

    // MARK: - From a key press

    func testOnlyTheFourModifiersCount() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function, .numericPad]
        XCTAssertEqual(KeyShortcut.carbonModifiers(from: flags), UInt32(cmdKey | shiftKey))
    }

    // MARK: - Rules

    func testAShortcutNeedsCommandOrOption() {
        XCTAssertEqual(shortcut(kVK_ANSI_K, shiftKey).problem, .needsCommandOrOption)
        XCTAssertNil(shortcut(kVK_ANSI_K, optionKey).problem)
        XCTAssertNil(shortcut(kVK_ANSI_W, cmdKey | optionKey).problem)
    }

    /// ⌃ is what sends the window to the clipboard instead.
    func testControlIsKeptForTheClipboard() {
        XCTAssertEqual(shortcut(kVK_ANSI_K, controlKey | cmdKey).problem, .controlIsForClipboard)
    }

    func testShortcutsScreenHereAndMacOSUseAreRefused() {
        XCTAssertEqual(shortcut(kVK_ANSI_3, shiftKey | cmdKey).problem, .usedBy("Screen"))
        XCTAssertEqual(shortcut(kVK_ANSI_7, shiftKey | cmdKey).problem, .usedBy("Text"))
        XCTAssertEqual(shortcut(kVK_ANSI_8, shiftKey | cmdKey).problem, .usedBy("History"))
        XCTAssertEqual(shortcut(kVK_ANSI_4, shiftKey | cmdKey).problem, .usedBy("macOS"))
        XCTAssertEqual(shortcut(kVK_ANSI_5, shiftKey | cmdKey).problem, .usedBy("macOS"))
        XCTAssertNil(KeyShortcut.shiftCommand2.problem)
    }

    func testCombosAddTheClipboardVariant() {
        let combos = shortcut(kVK_ANSI_W, cmdKey | optionKey).combos
        XCTAssertEqual(combos, [
            HotkeyCombo(id: HotkeyCombo.windowToDestinationID, keyCode: UInt32(kVK_ANSI_W),
                        carbonModifiers: UInt32(cmdKey | optionKey)),
            HotkeyCombo(id: HotkeyCombo.windowToClipboardID, keyCode: UInt32(kVK_ANSI_W),
                        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)),
        ])
    }
}
