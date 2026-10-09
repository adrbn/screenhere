import AppKit

/// ⇧⌘7: select a region, recognise its text on device, put it on the clipboard.
///
/// The selection itself is macOS's own (`screencapture -i`), for the same
/// reason ⇧⌘3 delegates to it: the crosshair, window picking, Escape and
/// multi-display handling are the system's and behave the way users expect.
@MainActor
enum TextCapture {
    private static var busy = false
    /// Ready, the reader answers in well under a second; past this something
    /// is wrong with it, and the fast engine answers instead.
    private static let accurateDeadline: TimeInterval = 3

    static func run() {
        guard !busy else { return }
        busy = true
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHere-text-\(UUID().uuidString.prefix(8)).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            Task { @MainActor in selectionEnded(file: file) }
        }
        do {
            try process.run()
        } catch {
            busy = false
        }
    }

    private static func selectionEnded(file: URL) {
        // Escape leaves no file behind: nothing to recognise, nothing to say.
        // The capture's bytes are kept rather than its pixels — the reader
        // service deletes the file, and the fast engine may still need it.
        guard let capture = try? Data(contentsOf: file) else {
            try? FileManager.default.removeItem(at: file)
            busy = false
            return
        }
        let reader = TextReader.shared
        switch reader.plan {
        case .accurate:
            reader.read(file, deadline: accurateDeadline) { text in
                if let text { finish(text) } else { recognizeFast(capture) }
            }
            return
        case .fastAndStart:
            reader.start()
        case .fast:
            break
        }
        try? FileManager.default.removeItem(at: file)
        recognizeFast(capture)
    }

    /// The fast engine reads in a throwaway process — see `FastReadService`
    /// for why.
    private static func recognizeFast(_ capture: Data) {
        FastReader.read(capture) { finish($0) }
    }

    private static func finish(_ text: String) {
        deliver(text)
        busy = false
    }

    private static func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Toast.show(TextCaptureStrings.copied(""), systemImage: "text.magnifyingglass")
            return
        }
        ClipboardController.shared.write(trimmed, source: "ScreenHere")
        Toast.show(TextCaptureStrings.copied(trimmed), systemImage: "doc.on.clipboard")
    }
}
