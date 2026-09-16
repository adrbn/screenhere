import XCTest
@testable import ScreenHere

/// ⇧⌘7 belongs to macOS out of the box — symbolic hotkey 181, "Save picture of
/// the Touch Bar as a file" — and a system shortcut beats an app's Carbon
/// hotkey, so without borrowing it ⇧⌘7 grabbed the Touch Bar instead of the
/// selection. Like ⇧⌘3 on a never-customised Mac, the entry is usually absent
/// from the user's preferences.
final class SymbolicHotkeyLeaseTests: XCTestCase {

    private let id = SymbolicHotkeyPlist.touchBarToFile

    private func lease(_ store: FakeSymbolicHotkeyStore, _ defaults: UserDefaults) -> SymbolicHotkeyLease {
        SymbolicHotkeyLease(id: id, keyCode: 26, modifiers: 1_179_648, store: store, defaults: defaults)
    }

    private func entry(enabled: Bool, keyCode: Int = 26, modifiers: Int = 1_179_648) -> [String: Any] {
        ["enabled": enabled,
         "value": ["type": "standard", "parameters": [55, keyCode, modifiers]] as [String: Any]]
    }

    func testAnAbsentEntryIsTheEnabledDefaultAndGetsBorrowed() {
        let store = FakeSymbolicHotkeyStore(entries: [:])
        let lease = lease(store, .makeTransient())
        XCTAssertEqual(lease.acquire(), .held)
        XCTAssertEqual(store.entries[id].map(SymbolicHotkeyPlist.isEnabled), false)
        XCTAssertGreaterThan(store.applyNowCallCount, 0)
    }

    func testReleaseGivesTheShortcutBack() {
        let store = FakeSymbolicHotkeyStore(entries: [:])
        let lease = lease(store, .makeTransient())
        _ = lease.acquire()
        lease.release()
        XCTAssertEqual(store.entries[id].map(SymbolicHotkeyPlist.isEnabled), true)
        XCTAssertEqual(store.entries[id].flatMap(SymbolicHotkeyPlist.parameters), [55, 26, 1_179_648])
        XCTAssertFalse(lease.isHeld)
    }

    /// A customised entry comes back exactly as it was, extra keys included.
    func testACustomisedEntryIsRestoredVerbatim() {
        var original = entry(enabled: true)
        original["note"] = "kept"
        let store = FakeSymbolicHotkeyStore(entries: [id: original])
        let lease = lease(store, .makeTransient())
        _ = lease.acquire()
        lease.release()
        XCTAssertEqual(store.entries[id]?["note"] as? String, "kept")
    }

    /// Moved to another key by the user: ⇧⌘7 is already free, hands off.
    func testAnEntryRemappedElsewhereIsLeftAlone() {
        let store = FakeSymbolicHotkeyStore(entries: [id: entry(enabled: true, keyCode: 22)])
        let lease = lease(store, .makeTransient())
        XCTAssertEqual(lease.acquire(), .notNeeded)
        XCTAssertEqual(store.entries[id].flatMap(SymbolicHotkeyPlist.parameters), [55, 22, 1_179_648])
        lease.release()
        XCTAssertEqual(store.entries[id].map(SymbolicHotkeyPlist.isEnabled), true)
    }

    /// Switched off by the user: nothing to borrow, and nothing to "restore"
    /// on quit — turning it back on would undo their choice.
    func testAnEntryTheUserDisabledStaysDisabled() {
        let store = FakeSymbolicHotkeyStore(entries: [id: entry(enabled: false)])
        let lease = lease(store, .makeTransient())
        XCTAssertEqual(lease.acquire(), .notNeeded)
        lease.release()
        XCTAssertEqual(store.entries[id].map(SymbolicHotkeyPlist.isEnabled), false)
    }

    func testAcquiringTwiceNeverSnapshotsTheDisabledEntry() {
        let store = FakeSymbolicHotkeyStore(entries: [:])
        let defaults = UserDefaults.makeTransient()
        let lease = lease(store, defaults)
        _ = lease.acquire()
        XCTAssertEqual(lease.acquire(), .held)
        lease.release()
        XCTAssertEqual(store.entries[id].map(SymbolicHotkeyPlist.isEnabled), true)
    }

    /// The write "succeeds" but macOS keeps the shortcut: report it rather than
    /// claim a combination the system will keep answering.
    func testAWriteMacOSIgnoresIsRefused() {
        let store = FakeSymbolicHotkeyStore(entries: [:])
        store.writesAreSilentlyIgnored = true
        let lease = lease(store, .makeTransient())
        XCTAssertEqual(lease.acquire(), .refused)
        XCTAssertFalse(lease.isHeld)
    }

    /// A run that died holding the shortcut: the next launch, with a fresh
    /// lease over the same preferences, can still give it back.
    func testALeaseSurvivesACrash() {
        let store = FakeSymbolicHotkeyStore(entries: [:])
        let defaults = UserDefaults.makeTransient()
        _ = lease(store, defaults).acquire()

        let afterRelaunch = lease(store, defaults)
        XCTAssertTrue(afterRelaunch.isHeld)
        afterRelaunch.release()
        XCTAssertEqual(store.entries[id].map(SymbolicHotkeyPlist.isEnabled), true)
    }

    func testReleasingWhatWasNeverHeldWritesNothing() {
        let store = FakeSymbolicHotkeyStore(entries: [id: entry(enabled: true)])
        lease(store, .makeTransient()).release()
        XCTAssertEqual(store.applyNowCallCount, 0)
    }
}
