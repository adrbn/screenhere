import Foundation
@testable import ScreenHere

/// An in-memory stand-in for com.apple.symbolichotkeys.
final class FakeSymbolicHotkeyStore: SymbolicHotkeyStore {
    var entries: [Int: [String: Any]]
    var applyNowResult = true
    var writeError: Error?
    private(set) var applyNowCallCount = 0

    init(entries: [Int: [String: Any]] = [
        SymbolicHotkeyPlist.screenshotToDestination: FakeSymbolicHotkeyStore.entry(modifiers: 1_179_648),
        SymbolicHotkeyPlist.screenshotToClipboard: FakeSymbolicHotkeyStore.entry(modifiers: 1_441_792),
    ]) {
        self.entries = entries
    }

    static func entry(modifiers: Int) -> [String: Any] {
        ["enabled": true,
         "value": ["type": "standard", "parameters": [51, 20, modifiers]] as [String: Any]]
    }

    func entry(_ id: Int) -> [String: Any]? { entries[id] }

    /// When true, `write` reports success but changes nothing — the way a
    /// `defaults write` that the system quietly ignores would behave.
    var writesAreSilentlyIgnored = false

    func write(_ entry: [String: Any], for id: Int) throws {
        if let writeError { throw writeError }
        guard !writesAreSilentlyIgnored else { return }
        entries[id] = entry
    }

    @discardableResult
    func applyNow() -> Bool {
        applyNowCallCount += 1
        return applyNowResult
    }
}

/// A stand-in for Carbon registration.
final class FakeHotkeyBinding: HotkeyBinding {
    var bindSucceeds = true
    private(set) var boundCombos: [HotkeyCombo] = []
    private(set) var unbindCallCount = 0
    private var onFire: ((UInt32) -> Void)?

    func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool {
        guard bindSucceeds else { return false }
        boundCombos = combos
        self.onFire = onFire
        return true
    }

    func unbindAll() {
        unbindCallCount += 1
        boundCombos = []
    }

    /// Simulates the user pressing a bound combination.
    func simulatePress(_ id: UInt32) { onFire?(id) }
}

/// Records capture requests instead of taking screenshots.
final class FakeCapture {
    private(set) var calls: [(destination: CaptureDestination, displayIndex: Int)] = []
    var displayIndexToReturn = 2

    func perform(destination: CaptureDestination, displayIndex: Int) {
        calls.append((destination, displayIndex))
    }
}

extension UserDefaults {
    /// A throwaway defaults domain so tests never touch the real one.
    static func makeTransient(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }
}
