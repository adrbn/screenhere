import Foundation

/// Owns the whole "borrow the system shortcut" state machine: disabling the
/// macOS symbolic hotkeys, holding the same combinations, capturing the right
/// display, and — the part that matters most — always being able to give the
/// shortcuts back.
final class TakeoverController {

    /// The app's single instance. Tests build their own with fakes; only the
    /// SwiftUI scene and the delegate need to reach the live one.
    static let shared = TakeoverController()


    enum Status: Equatable {
        case off
        case on
        /// Preferences written, but the window server did not reload them.
        case onPendingLogout
        case failed(String)
    }

    private enum Key {
        static let isOn = "TakeoverEnabled"
        /// Verbatim copies of the entries we replaced, keyed by hotkey id.
        static func original(_ id: Int) -> String { "OriginalSymbolicHotkey\(id)" }
    }

    private static let managedHotkeys = [
        SymbolicHotkeyPlist.screenshotToDestination,
        SymbolicHotkeyPlist.screenshotToClipboard,
    ]

    private let store: SymbolicHotkeyStore
    private let binding: HotkeyBinding
    private let defaults: UserDefaults
    private let capture: (CaptureDestination, Int) -> Void
    private let currentDisplayIndex: () -> Int

    private(set) var status: Status = .off

    /// Whether the macOS entries are, right now, actually disabled. Read from
    /// the live preferences rather than remembered from the write, so a
    /// shortcut re-enabled behind our back is visible instead of silent.
    var holdsShortcuts: Bool {
        Self.managedHotkeys.allSatisfy { id in
            // An absent entry is macOS's default, which is enabled — so we do
            // NOT hold the shortcut, however tempting the opposite reading is.
            guard let entry = store.entry(id) else { return false }
            return !SymbolicHotkeyPlist.isEnabled(entry)
        }
    }

    var isOn: Bool {
        if case .off = status { return false }
        if case .failed = status { return false }
        return true
    }

    init(store: SymbolicHotkeyStore = DefaultsSymbolicHotkeyStore(),
         binding: HotkeyBinding = HotkeyRegistrar(),
         defaults: UserDefaults = .standard,
         capture: @escaping (CaptureDestination, Int) -> Void = { destination, index in
             CaptureRunner.run(destination: destination, displayIndex: index)
         },
         currentDisplayIndex: @escaping () -> Int = { CursorDisplay.currentCaptureIndex() }) {
        self.store = store
        self.binding = binding
        self.defaults = defaults
        self.capture = capture
        self.currentDisplayIndex = currentDisplayIndex
    }

    // MARK: - Enable / disable

    func enable() {
        guard !isOn else { return }   // never re-snapshot an already-disabled entry

        for id in Self.managedHotkeys {
            // No entry means macOS is applying its built-in default, not that
            // there is nothing to do: write the stock definition disabled, or
            // the system keeps the shortcut and fires alongside us.
            guard let entry = store.entry(id) ?? SymbolicHotkeyPlist.stockEntry(for: id)
            else { continue }
            // Only snapshot an entry we have not already replaced, so a stale
            // "on" flag can never overwrite the real original with a disabled one.
            if SymbolicHotkeyPlist.isEnabled(entry) {
                saveOriginal(entry, for: id)
            }
            do {
                try store.write(SymbolicHotkeyPlist.disabled(entry), for: id)
            } catch {
                restoreOriginals()
                status = .failed(error.localizedDescription)
                return
            }
        }

        // Trusting the write is not enough. If the entries are still enabled,
        // macOS keeps handling ⇧⌘3 while we hold it too: every press fires both
        // handlers and the user gets a pile of screenshots instead of one.
        guard holdsShortcuts else {
            restoreOriginals()
            status = .failed("macOS would not release ⇧⌘3.")
            return
        }

        let applied = store.applyNow()

        guard binding.bind([.screenshotToDestination, .screenshotToClipboard],
                           onFire: { [weak self] id in self?.fire(comboID: id) }) else {
            restoreOriginals()
            status = .failed("Another app is already holding ⇧⌘3.")
            return
        }

        defaults.set(true, forKey: Key.isOn)
        status = applied ? .on : .onPendingLogout
    }

    func disable() {
        binding.unbindAll()
        restoreOriginals()
        status = .off
    }

    /// Called at launch. If a previous run disabled the shortcuts and never
    /// gave them back — a crash, a force quit, a logout mid-session — this
    /// puts them back before anything else happens.
    func healAfterUncleanExit() {
        guard defaults.bool(forKey: Key.isOn) else { return }
        restoreOriginals()
        status = .off
    }

    // MARK: - Firing

    func fire(comboID: UInt32) {
        let destination: CaptureDestination
        switch comboID {
        case HotkeyCombo.screenshotToDestination.id: destination = .userSettings
        case HotkeyCombo.screenshotToClipboard.id: destination = .clipboard
        default: return
        }
        capture(destination, currentDisplayIndex())
    }

    // MARK: - Original entries

    private func saveOriginal(_ entry: [String: Any], for id: Int) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: entry, format: .binary, options: 0) else { return }
        defaults.set(data, forKey: Key.original(id))
    }

    private func restoreOriginals() {
        for id in Self.managedHotkeys {
            guard let data = defaults.data(forKey: Key.original(id)),
                  let entry = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) as? [String: Any]
            else { continue }
            try? store.write(entry, for: id)
            defaults.removeObject(forKey: Key.original(id))
        }
        store.applyNow()
        defaults.set(false, forKey: Key.isOn)
    }
}
