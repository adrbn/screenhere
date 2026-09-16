import CoreGraphics
import os

/// A text recognition engine the reader service holds on to.
protocol TextEngine: AnyObject {
    func recognize(_ image: CGImage) throws -> String
}

/// The reader service's engine, judged on a sample it must read back.
///
/// On the macOS 27 beta the Neural Engine can stop running a model that has
/// been loaded and reading for an hour, and nothing Vision does in that process
/// works again — not even another model. A broken reader says so, and its
/// service ends so ScreenHere can start the next engine in a fresh process.
/// Failing on one capture does not break it: the capture may be what is wrong.
final class CheckedReader {
    private(set) var broken = false
    private let engine: TextEngine
    private let sample: CGImage
    private let expected: String
    private let log = Logger(subsystem: "com.screenhere.app", category: "text-reader-service")

    init(engine: TextEngine, sample: CGImage, expected: String) {
        self.engine = engine
        self.sample = sample
        self.expected = expected
    }

    /// Reads the sample, which loads the engine's models — compiling them
    /// first if their cache is stale.
    func warmUp() -> Bool {
        guard readsSample() else {
            broken = true
            log.error("The engine could not read its sample.")
            return false
        }
        return true
    }

    /// The capture's text, or nil when it could not be read.
    func read(_ image: CGImage) -> String? {
        guard !broken else { return nil }
        do {
            return try engine.recognize(image)
        } catch {
            if readsSample() {
                log.error("A capture could not be read: \(String(describing: error), privacy: .public)")
            } else {
                broken = true
                log.error("The engine stopped reading: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    private func readsSample() -> Bool {
        (try? engine.recognize(sample))?.contains(expected) ?? false
    }
}
