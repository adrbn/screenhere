import Foundation

/// Borrows one macOS symbolic hotkey for as long as ScreenHere needs its key
/// combination, and gives the entry back exactly as it found it.
///
/// A system shortcut beats an app's Carbon hotkey, so a combination macOS
/// assigns cannot simply be registered over. ⇧⌘7 is the case in point: out of
/// the box it is 181, "Save picture of the Touch Bar as a file".
///
/// The state lives in preferences, not memory, so a run that dies holding the
/// shortcut is recovered by the next launch.
final class SymbolicHotkeyLease {
    enum Outcome: Equatable {
        /// Disabled by us and held until `release()`.
        case held
        /// The user already moved or switched off that shortcut; the
        /// combination is free and nothing was touched.
        case notNeeded
        /// macOS kept the shortcut despite the write.
        case refused
    }

    let id: Int
    private let keyCode: Int
    private let modifiers: Int
    private let store: SymbolicHotkeyStore
    private let defaults: UserDefaults

    private var heldKey: String { "LeasedSymbolicHotkey\(id)" }
    private var originalKey: String { "LeasedSymbolicHotkeyOriginal\(id)" }

    init(id: Int, keyCode: Int, modifiers: Int,
         store: SymbolicHotkeyStore = DefaultsSymbolicHotkeyStore(),
         defaults: UserDefaults = .standard) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.store = store
        self.defaults = defaults
    }

    var isHeld: Bool { defaults.bool(forKey: heldKey) }

    func acquire() -> Outcome {
        guard !isHeld else { return .held }   // never snapshot our own disabled entry

        // Absent means macOS's built-in default, which is enabled.
        let entry = store.entry(id)
            ?? SymbolicHotkeyPlist.stockEntry(for: id)
            ?? [:]
        guard SymbolicHotkeyPlist.isEnabled(entry),
              let parameters = SymbolicHotkeyPlist.parameters(of: entry),
              parameters.count == 3, parameters[1] == keyCode, parameters[2] == modifiers
        else { return .notNeeded }

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: entry, format: .binary, options: 0) else { return .refused }
        defaults.set(data, forKey: originalKey)
        defaults.set(true, forKey: heldKey)

        do {
            try store.write(SymbolicHotkeyPlist.disabled(entry), for: id)
        } catch {
            release()
            return .refused
        }
        guard let written = store.entry(id), !SymbolicHotkeyPlist.isEnabled(written) else {
            release()
            return .refused
        }
        store.applyNow()
        return .held
    }

    func release() {
        guard isHeld else { return }
        if let data = defaults.data(forKey: originalKey),
           let original = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil) as? [String: Any] {
            try? store.write(original, for: id)
        }
        defaults.removeObject(forKey: originalKey)
        defaults.removeObject(forKey: heldKey)
        store.applyNow()
    }
}
