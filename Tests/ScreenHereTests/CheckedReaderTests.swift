import CoreGraphics
import XCTest
@testable import ScreenHere

/// The reader service's engine, judged on a sample it must read back. On the
/// macOS 27 beta the Neural Engine can stop running a model that has been
/// loaded and reading for an hour, and the process it failed in stays broken.
final class CheckedReaderTests: XCTestCase {

    private let sample = CheckedReaderTests.image(width: 1)
    private let capture = CheckedReaderTests.image(width: 2)

    func testAnEngineThatReadsTheSampleWarmsUpAndReads() {
        let reader = make(FakeEngine(text: "text"))
        XCTAssertTrue(reader.warmUp())
        XCTAssertEqual(reader.read(capture), "text")
        XCTAssertFalse(reader.broken)
    }

    func testAnEngineThatCannotReadTheSampleIsBroken() {
        let reader = make(FakeEngine(sample: .fails))
        XCTAssertFalse(reader.warmUp())
        XCTAssertTrue(reader.broken)
    }

    /// Reading without an error is not enough: the sample must come back right.
    func testAnEngineThatMisreadsTheSampleIsBroken() {
        let reader = make(FakeEngine(sample: .misreads))
        XCTAssertFalse(reader.warmUp())
        XCTAssertTrue(reader.broken)
    }

    /// What happened at 22:03: warm for an hour, then every read failing.
    func testAnEngineThatStopsReadingIsBrokenAndLeftAlone() {
        let engine = FakeEngine(text: "text")
        let reader = make(engine)
        XCTAssertTrue(reader.warmUp())
        engine.broken = true
        XCTAssertNil(reader.read(capture))
        XCTAssertTrue(reader.broken)
        XCTAssertNil(reader.read(capture))
        XCTAssertEqual(engine.reads, 3, "warm-up, the failed capture, the sample check — then never again")
    }

    /// A capture the engine cannot read, while it still reads the sample, is
    /// the capture's problem.
    func testACaptureTheEngineCannotReadLeavesItWorking() {
        let reader = make(FakeEngine(text: nil))
        XCTAssertTrue(reader.warmUp())
        XCTAssertNil(reader.read(capture))
        XCTAssertFalse(reader.broken)
    }

    func testEmptyTextIsARead() {
        let reader = make(FakeEngine(text: ""))
        XCTAssertTrue(reader.warmUp())
        XCTAssertEqual(reader.read(capture), "")
        XCTAssertFalse(reader.broken)
    }

    // MARK: - Helpers

    private func make(_ engine: FakeEngine) -> CheckedReader {
        CheckedReader(engine: engine, sample: sample, expected: "1234")
    }

    private static func image(width: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }
}

/// Which accurate engine a new reader service runs.
final class ReaderEngineTests: XCTestCase {

    func testEachEngineTravelsInItsArguments() {
        for engine in ReaderEngine.allCases {
            XCTAssertEqual(ReaderEngine(arguments: engine.arguments), engine)
        }
    }

    /// The current engine is the plain `--text-reader`, as before.
    func testTheCurrentEngineNeedsNoArgument() {
        XCTAssertEqual(ReaderEngine.current.arguments, [])
    }

    func testUnknownArgumentsAreRefused() {
        XCTAssertNil(ReaderEngine(arguments: ["3"]))
        XCTAssertNil(ReaderEngine(arguments: ["previous", "previous"]))
    }

    /// A failed engine hands over to the next, in a new process; past the last
    /// one it is a real failure, and the retry starts over from the best.
    func testEnginesHandOverInOrder() {
        XCTAssertEqual(ReaderEngine.current.next, .previous)
        XCTAssertNil(ReaderEngine.previous.next)
    }
}

/// Reads the 1-pixel-wide sample as "ScreenHere 1234" and anything else as `text`.
private final class FakeEngine: TextEngine {
    enum Sample { case reads, misreads, fails }
    struct Failure: Error {}

    var broken = false
    private(set) var reads = 0
    private let sample: Sample
    private let text: String?

    init(sample: Sample = .reads, text: String? = "text") {
        self.sample = sample
        self.text = text
    }

    func recognize(_ image: CGImage) throws -> String {
        reads += 1
        guard !broken else { throw Failure() }
        guard image.width == 1 else {
            guard let text else { throw Failure() }
            return text
        }
        switch sample {
        case .reads: return "ScreenHere 1234"
        case .misreads: return ""
        case .fails: throw Failure()
        }
    }
}
