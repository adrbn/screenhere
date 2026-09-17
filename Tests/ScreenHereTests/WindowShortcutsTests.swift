import Carbon.HIToolbox
import XCTest
@testable import ScreenHere

final class WindowShortcutsTests: XCTestCase {
    private let binding = FakeHotkeyBinding()
    private let defaults = UserDefaults.makeTransient()
    private var captures: [CaptureDestination] = []
    private let optionCommandW = KeyShortcut(keyCode: UInt32(kVK_ANSI_W),
                                             carbonModifiers: UInt32(optionKey | cmdKey))

    private func make() -> WindowShortcuts {
        let shortcuts = WindowShortcuts(binding: binding, defaults: defaults,
                                        capture: { self.captures.append($0) })
        shortcuts.activate()
        return shortcuts
    }

    func testOffByDefaultOnShiftCommand2() {
        let shortcuts = make()
        XCTAssertFalse(shortcuts.isEnabled)
        XCTAssertEqual(shortcuts.shortcut, .shiftCommand2)
        XCTAssertEqual(binding.boundCombos, [])
    }

    func testTurningOnRegistersTheShortcutAndItsClipboardVariant() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        XCTAssertEqual(binding.boundCombos, KeyShortcut.shiftCommand2.combos)

        binding.simulatePress(HotkeyCombo.windowToDestinationID)
        binding.simulatePress(HotkeyCombo.windowToClipboardID)
        XCTAssertEqual(captures, [.userSettings, .clipboard])
    }

    func testTurningOffUnregisters() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        shortcuts.setEnabled(false)
        XCTAssertEqual(binding.boundCombos, [])
    }

    func testARecordedShortcutReplacesTheDefault() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        XCTAssertNil(shortcuts.setShortcut(optionCommandW))
        XCTAssertEqual(shortcuts.shortcut, optionCommandW)
        XCTAssertEqual(binding.boundCombos, optionCommandW.combos)
    }

    func testARefusedShortcutChangesNothing() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        let screen = KeyShortcut(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(shiftKey | cmdKey))
        XCTAssertEqual(shortcuts.setShortcut(screen), .usedBy("Screen"))
        XCTAssertEqual(shortcuts.shortcut, .shiftCommand2)
        XCTAssertEqual(binding.boundCombos, KeyShortcut.shiftCommand2.combos)
    }

    func testResettingGoesBackToShiftCommand2() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        shortcuts.setShortcut(optionCommandW)
        shortcuts.resetShortcut()
        XCTAssertEqual(shortcuts.shortcut, .shiftCommand2)
        XCTAssertEqual(binding.boundCombos, KeyShortcut.shiftCommand2.combos)
        XCTAssertEqual(make().shortcut, .shiftCommand2)
    }

    func testTheChoiceSurvivesARelaunch() {
        let first = make()
        first.setEnabled(true)
        first.setShortcut(optionCommandW)
        let second = make()
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.shortcut, optionCommandW)
    }

    /// Recording adds nothing to undo: a menu that closes halfway through
    /// cannot leave the shortcut switched off.
    func testRecordingLeavesTheShortcutRegistered() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        shortcuts.beginRecording()
        XCTAssertEqual(binding.boundCombos, KeyShortcut.shiftCommand2.combos)
        shortcuts.endRecording()
        XCTAssertEqual(binding.boundCombos, KeyShortcut.shiftCommand2.combos)
    }

    /// Pressing the shortcut it already has, while typing a new one, means
    /// keeping it — not capturing a window behind the menu.
    func testPressingTheCurrentShortcutWhileRecordingKeepsItAndCapturesNothing() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        shortcuts.beginRecording()
        binding.simulatePress(HotkeyCombo.windowToDestinationID)
        XCTAssertEqual(captures, [])
        XCTAssertFalse(shortcuts.isRecording)
        XCTAssertEqual(shortcuts.shortcut, .shiftCommand2)
        binding.simulatePress(HotkeyCombo.windowToDestinationID)
        XCTAssertEqual(captures, [.userSettings])
    }

    func testARecordedShortcutEndsTheRecording() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        shortcuts.beginRecording()
        shortcuts.setShortcut(optionCommandW)
        XCTAssertFalse(shortcuts.isRecording)
        XCTAssertEqual(binding.boundCombos, optionCommandW.combos)
    }

    func testARefusedShortcutKeepsTheRecordingGoing() {
        let shortcuts = make()
        shortcuts.setEnabled(true)
        shortcuts.beginRecording()
        let screen = KeyShortcut(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(shiftKey | cmdKey))
        XCTAssertEqual(shortcuts.setShortcut(screen), .usedBy("Screen"))
        XCTAssertTrue(shortcuts.isRecording)
    }

    func testRecordingWhileOffRegistersNothing() {
        let shortcuts = make()
        shortcuts.beginRecording()
        shortcuts.setShortcut(optionCommandW)
        shortcuts.endRecording()
        XCTAssertEqual(binding.boundCombos, [])
    }

    func testAShortcutAnotherAppHoldsIsReported() {
        binding.bindSucceeds = false
        let shortcuts = make()
        shortcuts.setEnabled(true)
        XCTAssertTrue(shortcuts.shortcutUnavailable)
        shortcuts.setEnabled(false)
        XCTAssertFalse(shortcuts.shortcutUnavailable)
    }

    /// A hand-edited or damaged preference must not leave the feature on a
    /// shortcut the rules refuse.
    func testAStoredShortcutTheRulesRefuseFallsBackToTheDefault() {
        defaults.set(["keyCode": kVK_ANSI_3, "modifiers": shiftKey | cmdKey], forKey: WindowPrefs.shortcutKey)
        XCTAssertEqual(make().shortcut, .shiftCommand2)
    }
}
