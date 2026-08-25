import Foundation

/// Read/write access to the macOS symbolic hotkeys, behind a protocol so the
/// controller can be tested without touching the user's real preferences.
protocol SymbolicHotkeyStore {
    /// The complete current entry for a symbolic hotkey id, or nil if absent.
    func entry(_ id: Int) -> [String: Any]?
    /// Merges `entry` into `AppleSymbolicHotKeys` under `id`.
    func write(_ entry: [String: Any], for id: Int) throws
    /// Asks the window server to re-read the hotkey table. Returns false when
    /// the change will only take effect at the next login.
    @discardableResult func applyNow() -> Bool
}

struct DefaultsSymbolicHotkeyStore: SymbolicHotkeyStore {
    private static let domain = "com.apple.symbolichotkeys"
    private static let key = "AppleSymbolicHotKeys"
    private static let activateSettings =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    enum Failure: Error, LocalizedError {
        case writeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let code):
                return "`defaults write` failed with exit code \(code)."
            }
        }
    }

    func entry(_ id: Int) -> [String: Any]? {
        // `defaults export` goes through cfprefsd, so it always reflects
        // pending writes — reading the .plist file directly does not.
        guard let output = Self.run("/usr/bin/defaults",
                                    ["export", Self.domain, "-"]).standardOutput,
              let plist = try? PropertyListSerialization.propertyList(
                  from: output, options: [], format: nil) as? [String: Any],
              let table = plist[Self.key] as? [String: Any],
              let raw = table[String(id)] as? [String: Any]
        else { return nil }
        return raw
    }

    func write(_ entry: [String: Any], for id: Int) throws {
        let xml = try SymbolicHotkeyPlist.xml(from: entry)
        let result = Self.run("/usr/bin/defaults",
                              ["write", Self.domain, Self.key, "-dict-add", String(id), xml])
        guard result.status == 0 else { throw Failure.writeFailed(result.status) }
    }

    @discardableResult
    func applyNow() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.activateSettings) else {
            return false
        }
        return Self.run(Self.activateSettings, ["-u"]).status == 0
    }

    // MARK: - Process helper

    private static func run(_ path: String, _ arguments: [String])
        -> (status: Int32, standardOutput: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
