import Foundation

/// The history on disk: one JSON file in Application Support, readable by its
/// owner only, since it holds whatever the user copied.
struct ClipboardHistoryStore {
    let directory: URL

    init(directory: URL = ClipboardHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenHere", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent("ClipboardHistory.json") }

    /// A missing or unreadable file is an empty history, never a failure: the
    /// feature has to keep working after a damaged write.
    func load() -> ClipboardHistory {
        guard let data = try? Data(contentsOf: fileURL),
              let history = try? JSONDecoder().decode(ClipboardHistory.self, from: data)
        else { return .empty }
        return history
    }

    func save(_ history: ClipboardHistory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(history)
        try data.write(to: fileURL, options: [.atomic])
        // Set after the atomic rename, which replaces the file and its mode.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
