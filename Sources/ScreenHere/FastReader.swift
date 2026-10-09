import AppKit

/// Reads the words in an image with the fast engine, in a throwaway process —
/// see `FastReadService` for why Vision never runs inside ScreenHere itself.
@MainActor
enum FastReader {
    /// A reader stuck on the Neural Engine must not hold its caller for ever:
    /// killing it closes the pipe, and the read below ends.
    private static let limit: TimeInterval = 20

    /// Answers with the words read, empty when there were none or the reader
    /// could not be run at all. `background` is for reading ScreenHere asked
    /// for itself, which must stay out of the user's way.
    static func read(_ capture: Data, background: Bool = false,
                     answer: @escaping @MainActor (String) -> Void) {
        guard let executable = Bundle.main.executableURL else {
            answer("")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [FastReadService.argument]
        process.qualityOfService = background ? .utility : .userInitiated
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A reader that died must fail the write, not kill ScreenHere.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            answer("")
            return
        }
        DispatchQueue.global(qos: background ? .utility : .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: capture)
            try? input.fileHandleForWriting.close()
            // The reader answers once it has the whole capture, so writing it
            // all and then reading cannot deadlock on the pipes.
            let text = ((try? output.fileHandleForReading.readToEnd()) ?? nil)
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            Task { @MainActor in answer(text) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            if process.isRunning { process.terminate() }
        }
    }
}
