import Foundation

/// Pure transforms on one entry of the `AppleSymbolicHotKeys` dictionary.
///
/// An entry looks like:
/// ```
/// { enabled = 1; value = { type = standard; parameters = (51, 20, 1179648); }; }
/// ```
/// where `parameters` is `[charCode, keyCode, modifierMask]`. The modifier
/// mask uses the Cocoa bits: shift 131072, control 262144, option 524288,
/// command 1048576.
enum SymbolicHotkeyPlist {

    /// "Save picture of screen" — ⇧⌘3.
    static let screenshotToDestination = 28
    /// "Copy picture of screen to the clipboard" — ⌃⇧⌘3.
    static let screenshotToClipboard = 29

    enum Failure: Error, LocalizedError {
        case notAPropertyList
        case notADictionary
        case notUTF8

        var errorDescription: String? {
            switch self {
            case .notAPropertyList: return "The hotkey entry is not a valid property list."
            case .notADictionary: return "The hotkey entry is not a dictionary."
            case .notUTF8: return "The hotkey entry could not be encoded as UTF-8."
            }
        }
    }

    /// macOS only writes an entry once the user customises that shortcut. On a
    /// stock Mac there is no entry at all and the built-in default applies — so
    /// "absent" means "enabled", and taking the shortcut over means writing the
    /// stock definition ourselves rather than skipping it.
    ///
    /// 51 is ASCII "3", 20 is kVK_ANSI_3, and the masks are shift+command and
    /// control+shift+command in Cocoa's bit layout.
    static func stockEntry(for id: Int) -> [String: Any]? {
        let modifiers: Int
        switch id {
        case screenshotToDestination: modifiers = 1_179_648
        case screenshotToClipboard: modifiers = 1_441_792
        default: return nil
        }
        return [
            "enabled": true,
            "value": ["type": "standard", "parameters": [51, 20, modifiers]] as [String: Any],
        ]
    }

    static func isEnabled(_ entry: [String: Any]) -> Bool {
        (entry["enabled"] as? NSNumber)?.boolValue ?? false
    }

    /// A copy of `entry` with `enabled` false and every other key preserved
    /// verbatim — including `value ▸ parameters`, without which macOS cannot
    /// re-arm the shortcut when we hand it back.
    static func disabled(_ entry: [String: Any]) -> [String: Any] {
        var copy = entry
        copy["enabled"] = false
        return copy
    }

    /// XML plist text, the form `defaults write … -dict-add` accepts.
    static func xml(from entry: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entry, format: .xml, options: 0)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }

    static func entry(fromXML xml: String) throws -> [String: Any] {
        guard let data = xml.data(using: .utf8) else { throw Failure.notUTF8 }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) else { throw Failure.notAPropertyList }
        guard let dictionary = object as? [String: Any] else { throw Failure.notADictionary }
        return dictionary
    }
}
