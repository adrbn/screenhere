import AppKit

/// The reader service's side: ScreenHere's own binary, launched with
/// `argument`, reading captures with the accurate engine for as long as
/// ScreenHere runs. It never brings up the app — no menu-bar icon, no hotkeys.
///
/// Idle, it sleeps on its input and costs nothing but its memory. It exits when
/// ScreenHere closes the pipe (quit, crash, ⇧⌘7 turned off) and when memory
/// runs critically short; the next capture starts another.
enum ReaderService {
    static let argument = "--text-reader"

    /// `arguments` are the ones after `argument`, naming the engine.
    static func run(arguments: [String]) -> Int32 {
        // ScreenHere gone mid-reply: a failed write ends the loop instead.
        signal(SIGPIPE, SIG_IGN)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
        pressure.setEventHandler { exit(0) }
        pressure.resume()

        guard let engine = ReaderEngine(arguments: arguments), let sample = render("ScreenHere 1234") else {
            send(ReaderProtocol.failed)
            return 1
        }
        let reader = CheckedReader(engine: LastingRecognizer(engine: engine), sample: sample, expected: "1234")
        guard reader.warmUp() else {
            send(ReaderProtocol.failed)
            return 1
        }
        guard send(ReaderProtocol.ready) else { return 0 }

        while let line = readLine() {
            guard let request = ReaderProtocol.parseRequest(line) else { continue }
            let text = read(URL(fileURLWithPath: request.path), with: reader)
            guard send(ReaderProtocol.reply(id: request.id, text: text)) else { return 0 }
            // Nothing will read in this process again: ScreenHere starts the
            // next engine in a fresh one.
            if reader.broken {
                send(ReaderProtocol.failed)
                return 1
            }
        }
        return 0
    }

    /// Someone is waiting on a capture: it runs ahead of the service's own
    /// utility-level work.
    private static func read(_ file: URL, with reader: CheckedReader) -> String? {
        var text: String?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if let image = TextRecognizer.image(at: file) {
                text = reader.read(image)
            }
            done.signal()
        }
        done.wait()
        return text
    }

    @discardableResult
    private static func send(_ line: String) -> Bool {
        do {
            try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    private static func render(_ text: String) -> CGImage? {
        let size = NSSize(width: 420, height: 80)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 16, y: 24), withAttributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black,
            ])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
