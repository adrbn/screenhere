import AppKit
import Carbon.HIToolbox

/// A key and its modifiers, as the user records it for capturing a window.
struct KeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let shiftCommand2 = KeyShortcut(keyCode: UInt32(kVK_ANSI_2),
                                           carbonModifiers: UInt32(shiftKey | cmdKey))

    /// Why a shortcut cannot be used, in the words the recorder shows.
    enum Problem: Equatable {
        case needsCommandOrOption
        case controlIsForClipboard
        case usedBy(String)

        var message: String {
            switch self {
            case .needsCommandOrOption: return "Add ⌘ or ⌥"
            case .controlIsForClipboard: return "⌃ is for the clipboard"
            case .usedBy(let owner): return "Used by \(owner)"
            }
        }
    }

    /// Shortcuts that already mean something: ScreenHere's own, and macOS's
    /// screenshot ones, which never even reach the recorder.
    private static let taken: [(keyCode: Int, owner: String)] = [
        (kVK_ANSI_3, "Screen"), (kVK_ANSI_7, "Text"), (kVK_ANSI_8, "History"),
        (kVK_ANSI_4, "macOS"), (kVK_ANSI_5, "macOS"), (kVK_ANSI_6, "macOS"),
    ]

    var problem: Problem? {
        if carbonModifiers & UInt32(controlKey) != 0 { return .controlIsForClipboard }
        if carbonModifiers & UInt32(cmdKey | optionKey) == 0 { return .needsCommandOrOption }
        if carbonModifiers == UInt32(shiftKey | cmdKey),
           let owner = Self.taken.first(where: { UInt32($0.keyCode) == keyCode })?.owner {
            return .usedBy(owner)
        }
        return nil
    }

    /// The shortcut, and with ⌃ added the same capture to the clipboard, as
    /// ⌃⇧⌘3 does for the screen.
    var combos: [HotkeyCombo] {
        [HotkeyCombo(id: HotkeyCombo.windowToDestinationID, keyCode: keyCode,
                     carbonModifiers: carbonModifiers),
         HotkeyCombo(id: HotkeyCombo.windowToClipboardID, keyCode: keyCode,
                     carbonModifiers: carbonModifiers | UInt32(controlKey))]
    }

    // MARK: - From a key press

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode),
                  carbonModifiers: Self.carbonModifiers(from: event.modifierFlags))
    }

    /// Only ⌃⌥⇧⌘ count. Caps Lock, fn and the keypad flag do not.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        return UInt32(modifiers)
    }

    // MARK: - Label

    /// In the order macOS writes them: ⌃⌥⇧⌘.
    static func symbols(for carbonModifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { carbonModifiers & UInt32($0.0) != 0 }
            .map(\.1)
            .joined()
    }

    /// `typed` says what the key types on the current keyboard, with or
    /// without ⇧.
    func label(typed: (UInt32, Bool) -> String? = KeyNames.typed) -> String {
        Self.symbols(for: carbonModifiers) + KeyNames.name(of: keyCode, typed: typed)
    }
}

enum KeyNames {
    private static let named: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18,
                            kVK_F19, kVK_F20]
        for (index, key) in functionKeys.enumerated() { names[key] = "F\(index + 1)" }
        return names
    }()

    /// The key as people call it: its name, or what it types. A digit wins
    /// over what the key types without ⇧, so the French keyboard's é key
    /// reads 2, as printed on it.
    static func name(of keyCode: UInt32, typed: (UInt32, Bool) -> String?) -> String {
        if let name = named[Int(keyCode)] { return name }
        let plain = typed(keyCode, false)
        if let shifted = typed(keyCode, true), isDigit(shifted), !(plain.map(isDigit) ?? false) {
            return shifted
        }
        return plain?.uppercased() ?? "?"
    }

    private static func isDigit(_ text: String) -> Bool {
        text.count == 1 && text.first?.isASCII == true && text.first?.isNumber == true
    }

    /// What the key types on the current keyboard layout. Main thread only,
    /// as the Text Input Sources calls are.
    static func typed(_ keyCode: UInt32, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifierState = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), modifierState,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
