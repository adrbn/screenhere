import XCTest
@testable import ScreenHere

final class TakeoverControllerTests: XCTestCase {

    private func makeController(
        store: FakeSymbolicHotkeyStore = FakeSymbolicHotkeyStore(),
        binding: FakeHotkeyBinding = FakeHotkeyBinding(),
        capture: FakeCapture = FakeCapture(),
        defaults: UserDefaults = .makeTransient()
    ) -> TakeoverController {
        TakeoverController(
            store: store, binding: binding, defaults: defaults,
            capture: { capture.perform(destination: $0, displayIndex: $1) },
            currentDisplayIndex: { capture.displayIndexToReturn })
    }

    // MARK: - Enabling

    func testEnablingDisablesBothSystemShortcuts() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.enable()

        for id in [SymbolicHotkeyPlist.screenshotToDestination,
                   SymbolicHotkeyPlist.screenshotToClipboard] {
            XCTAssertFalse(SymbolicHotkeyPlist.isEnabled(store.entries[id]!),
                           "symbolic hotkey \(id) should be disabled")
        }
        XCTAssertEqual(controller.status, .on)
    }

    func testEnablingPreservesTheParametersSoRestoreCanWork() {
        let store = FakeSymbolicHotkeyStore()
        makeController(store: store).enable()
        let value = store.entries[SymbolicHotkeyPlist.screenshotToDestination]?["value"] as? [String: Any]
        XCTAssertEqual(value?["parameters"] as? [Int], [51, 20, 1_179_648])
    }

    func testEnablingBindsBothCombos() {
        let binding = FakeHotkeyBinding()
        makeController(binding: binding).enable()
        XCTAssertEqual(binding.boundCombos,
                       [.screenshotToDestination, .screenshotToClipboard])
    }

    func testEnablingAsksTheWindowServerToReloadTheHotkeyTable() {
        let store = FakeSymbolicHotkeyStore()
        makeController(store: store).enable()
        XCTAssertEqual(store.applyNowCallCount, 1)
    }

    func testEnablingReportsPendingLogoutWhenTheChangeCannotBeAppliedLive() {
        let store = FakeSymbolicHotkeyStore()
        store.applyNowResult = false
        let controller = makeController(store: store)
        controller.enable()
        XCTAssertEqual(controller.status, .onPendingLogout)
    }

    /// If Carbon refuses the combos, macOS must get its shortcuts back
    /// immediately — otherwise ⇧⌘3 is dead for everyone.
    func testFailedBindingRollsTheSystemShortcutsBack() {
        let store = FakeSymbolicHotkeyStore()
        let binding = FakeHotkeyBinding()
        binding.bindSucceeds = false
        let controller = makeController(store: store, binding: binding)
        controller.enable()

        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(
            store.entries[SymbolicHotkeyPlist.screenshotToDestination]!))
        XCTAssertFalse(controller.isOn)
        if case .failed = controller.status {} else {
            XCTFail("expected a failed status, got \(controller.status)")
        }
    }

    func testEnablingTwiceIsIdempotent() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.enable()
        controller.enable()
        // The second enable must not capture the already-disabled entry as
        // the "original", which would make restore a no-op forever.
        controller.disable()
        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(
            store.entries[SymbolicHotkeyPlist.screenshotToDestination]!))
    }

    /// The failure a user actually hits: the write is accepted, nothing
    /// changes, and macOS keeps handling ⇧⌘3 — so both handlers fire and every
    /// press produces a pile of screenshots. Trusting the write is not enough;
    /// the entries have to be read back.
    func testEnablingFailsWhenTheSystemSilentlyIgnoresTheWrite() {
        let store = FakeSymbolicHotkeyStore()
        store.writesAreSilentlyIgnored = true
        let controller = makeController(store: store)
        controller.enable()

        XCTAssertFalse(controller.isOn)
        if case .failed = controller.status {} else {
            XCTFail("expected a failed status, got \(controller.status)")
        }
    }

    func testAShortcutReEnabledBehindOurBackIsReported() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.enable()
        XCTAssertTrue(controller.holdsShortcuts)

        // Something else — the user, another app, a settings sync — turned it
        // back on. macOS is handling ⇧⌘3 again and we would be duplicating it.
        store.entries[SymbolicHotkeyPlist.screenshotToDestination] =
            FakeSymbolicHotkeyStore.entry(modifiers: 1_179_648)
        XCTAssertFalse(controller.holdsShortcuts)
    }

    // MARK: - Disabling

    func testDisablingRestoresTheOriginalEntriesVerbatim() {
        let store = FakeSymbolicHotkeyStore()
        let originals = store.entries
        let controller = makeController(store: store)
        controller.enable()
        controller.disable()

        for (id, original) in originals {
            XCTAssertEqual(NSDictionary(dictionary: store.entries[id]!),
                           NSDictionary(dictionary: original))
        }
        XCTAssertEqual(controller.status, .off)
    }

    func testDisablingUnbindsTheCombos() {
        let binding = FakeHotkeyBinding()
        let controller = makeController(binding: binding)
        controller.enable()
        controller.disable()
        XCTAssertTrue(binding.boundCombos.isEmpty)
    }

    // MARK: - Recovery

    /// The scenario that must never strand the user: ScreenHere disabled the
    /// shortcuts, then died before restoring them.
    func testHealAfterUncleanExitRestoresShortcutsFromTheStoredOriginals() {
        let defaults = UserDefaults.makeTransient()
        let store = FakeSymbolicHotkeyStore()
        let originals = store.entries

        // First life: enable, then vanish without disabling.
        makeController(store: store, defaults: defaults).enable()

        // Second life: a fresh controller over the same persisted state.
        let reborn = makeController(store: store, defaults: defaults)
        reborn.healAfterUncleanExit()

        for (id, original) in originals {
            XCTAssertEqual(NSDictionary(dictionary: store.entries[id]!),
                           NSDictionary(dictionary: original))
        }
        XCTAssertEqual(reborn.status, .off)
    }

    func testHealDoesNothingWhenScreenHereNeverTookOver() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.healAfterUncleanExit()
        XCTAssertEqual(store.applyNowCallCount, 0)
        XCTAssertEqual(controller.status, .off)
    }

    // MARK: - Firing

    func testShiftCommandThreeCapturesTheDisplayUnderThePointerWithUserSettings() {
        let capture = FakeCapture()
        capture.displayIndexToReturn = 2
        let binding = FakeHotkeyBinding()
        // Hold the controller: the fire callback is [weak self], so a
        // discarded controller would silently swallow the press.
        let controller = makeController(binding: binding, capture: capture)
        controller.enable()

        binding.simulatePress(HotkeyCombo.screenshotToDestination.id)
        XCTAssertTrue(controller.isOn)

        XCTAssertEqual(capture.calls.count, 1)
        XCTAssertEqual(capture.calls.first?.displayIndex, 2)
        XCTAssertEqual(capture.calls.first?.destination, .userSettings)
    }

    func testControlShiftCommandThreeForcesTheClipboard() {
        let capture = FakeCapture()
        capture.displayIndexToReturn = 1
        let binding = FakeHotkeyBinding()
        let controller = makeController(binding: binding, capture: capture)
        controller.enable()

        binding.simulatePress(HotkeyCombo.screenshotToClipboard.id)
        XCTAssertTrue(controller.isOn)

        XCTAssertEqual(capture.calls.first?.displayIndex, 1)
        XCTAssertEqual(capture.calls.first?.destination, .clipboard)
    }

    func testUnknownComboIdentifierIsIgnored() {
        let capture = FakeCapture()
        let binding = FakeHotkeyBinding()
        let controller = makeController(binding: binding, capture: capture)
        controller.enable()
        binding.simulatePress(99)
        XCTAssertTrue(controller.isOn)
        XCTAssertTrue(capture.calls.isEmpty)
    }
}
