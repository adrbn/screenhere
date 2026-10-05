import AppKit

/// The fast engine's side: ScreenHere's own binary, launched with `argument`
/// to read one capture and exit. The capture comes in on standard input, the
/// text goes out on standard output — one read, no protocol to speak of.
///
/// It exists for the same reason the accurate reader is a service: Vision can
/// leave the process it ran in broken. On the macOS 27 beta a fast read inside
/// ScreenHere took the app down with a segmentation fault half a second later,
/// in unrelated code. Nothing of Vision runs in ScreenHere itself any more.
enum FastReadService {
    static let argument = "--text-fast"

    static func run() -> Int32 {
        // ScreenHere gone mid-reply: a failed write ends this, not a signal.
        signal(SIGPIPE, SIG_IGN)
        guard let text = read((try? FileHandle.standardInput.readToEnd()) ?? nil) else { return 1 }
        do {
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
        } catch {
            return 1
        }
        return 0
    }

    /// The capture's text, or nil when its bytes are not an image Vision can
    /// be given at all.
    static func read(_ capture: Data?) -> String? {
        guard let capture, let image = TextRecognizer.image(from: capture) else { return nil }
        return try? TextRecognizer.recognize(image, level: .fast)
    }
}
