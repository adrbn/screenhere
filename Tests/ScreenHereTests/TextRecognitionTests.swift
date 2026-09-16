import XCTest
@testable import ScreenHere

final class RecognitionLanguagesTests: XCTestCase {

    private let supported = ["en-US", "fr-FR", "de-DE", "tr-TR", "zh-Hans", "zh-Hant"]

    func testPreferredLanguagesComeFirstThenEnglish() {
        XCTAssertEqual(RecognitionLanguages.pick(preferred: ["fr-FR"], supported: supported),
                       ["fr-FR", "en-US"])
    }

    /// macOS reports regional variants Vision does not list ("fr-CA"); the
    /// language code is what matters.
    func testRegionalVariantsMapToTheSupportedOne() {
        XCTAssertEqual(RecognitionLanguages.pick(preferred: ["fr-CA", "tr"], supported: supported),
                       ["fr-FR", "tr-TR", "en-US"])
    }

    func testScriptSubtagsAreRespected() {
        XCTAssertEqual(RecognitionLanguages.pick(preferred: ["zh-Hant-TW"], supported: supported),
                       ["zh-Hant", "en-US"])
    }

    func testUnsupportedPreferencesFallBackToEnglish() {
        XCTAssertEqual(RecognitionLanguages.pick(preferred: ["xx-YY"], supported: supported),
                       ["en-US"])
    }

    func testNoDuplicates() {
        XCTAssertEqual(RecognitionLanguages.pick(preferred: ["en-GB", "en-US", "fr"], supported: supported),
                       ["en-US", "fr-FR"])
    }
}

/// Which engine a capture uses. The accurate one lives in a reader service
/// that keeps Vision's models loaded: loading them can mean a ~40–110s compile
/// on the macOS 27 beta, and a fresh process pays it again at random.
final class RecognitionPlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 5_000)

    func testAReadyReaderIsUsed() {
        XCTAssertEqual(RecognitionPlan.decide(reader: .ready, failures: 0, lastFailure: nil, now: now), .accurate)
    }

    func testAStoppedReaderAnswersFastAndStarts() {
        XCTAssertEqual(RecognitionPlan.decide(reader: .stopped, failures: 0, lastFailure: nil, now: now), .fastAndStart)
    }

    /// Loading may be a minute-long compile, and a busy reader may be stuck
    /// on one: neither holds the capture up.
    func testALoadingOrBusyReaderLeavesItToTheFastEngine() {
        XCTAssertEqual(RecognitionPlan.decide(reader: .loading, failures: 0, lastFailure: nil, now: now), .fast)
        XCTAssertEqual(RecognitionPlan.decide(reader: .reading, failures: 0, lastFailure: nil, now: now), .fast)
    }

    /// Every load that fails has cost a model compile first. A reader that
    /// keeps failing — the beta's Neural Engine compiler sometimes refuses
    /// every model for a while — is retried further and further apart.
    func testAFailedReaderIsRetriedFurtherApartEachTime() {
        func plan(failures: Int, minutesAgo: Double) -> RecognitionPlan {
            RecognitionPlan.decide(reader: .stopped, failures: failures,
                                   lastFailure: now.addingTimeInterval(-minutesAgo * 60), now: now)
        }
        XCTAssertEqual(plan(failures: 1, minutesAgo: 1), .fast)
        XCTAssertEqual(plan(failures: 1, minutesAgo: 3), .fastAndStart)
        XCTAssertEqual(plan(failures: 2, minutesAgo: 9), .fast)
        XCTAssertEqual(plan(failures: 2, minutesAgo: 11), .fastAndStart)
        XCTAssertEqual(plan(failures: 3, minutesAgo: 49), .fast)
        XCTAssertEqual(plan(failures: 3, minutesAgo: 51), .fastAndStart)
        XCTAssertEqual(plan(failures: 9, minutesAgo: 59), .fast)
        XCTAssertEqual(plan(failures: 9, minutesAgo: 61), .fastAndStart)
    }
}

final class ReaderProtocolTests: XCTestCase {

    func testARequestRoundTrips() throws {
        let file = URL(fileURLWithPath: "/tmp/ScreenHere text 1a2b.png")
        let line = try XCTUnwrap(ReaderProtocol.request(id: 7, file: file))
        let request = try XCTUnwrap(ReaderProtocol.parseRequest(line))
        XCTAssertEqual(request.id, 7)
        XCTAssertEqual(request.path, file.path)
    }

    /// A path that would break the one-line framing is refused, not sent.
    func testAPathThatCannotTravelOnOneLineIsRefused() {
        XCTAssertNil(ReaderProtocol.request(id: 1, file: URL(fileURLWithPath: "/tmp/a\nb.png")))
        XCTAssertNil(ReaderProtocol.request(id: 1, file: URL(fileURLWithPath: "/tmp/a\tb.png")))
    }

    /// Recognised text spans lines and holds tabs: it must still be one reply.
    func testTextWithNewlinesTabsAndAccentsIsOneReply() {
        let text = "Il reste à tester\n1.\t« Copied X words »\n"
        let line = ReaderProtocol.reply(id: 3, text: text)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(ReaderProtocol.parseReply(line), .read(id: 3, text: text))
    }

    func testEmptyTextIsNotAFailure() {
        XCTAssertEqual(ReaderProtocol.parseReply(ReaderProtocol.reply(id: 4, text: "")), .read(id: 4, text: ""))
    }

    func testAFailedReadRoundTrips() {
        XCTAssertEqual(ReaderProtocol.parseReply(ReaderProtocol.reply(id: 5, text: nil)), .read(id: 5, text: nil))
    }

    func testReadyAndFailed() {
        XCTAssertEqual(ReaderProtocol.parseReply(ReaderProtocol.ready), .ready)
        XCTAssertEqual(ReaderProtocol.parseReply(ReaderProtocol.failed), .failed)
    }

    func testGarbageIsIgnored() {
        for line in ["", "hello", "x\tok\tAAAA", "2\tok\t%%%", "2\tmaybe", "-1\tfail"] {
            XCTAssertNil(ReaderProtocol.parseReply(line), line)
        }
        for line in ["", "7", "x\t/tmp/a.png", "7\t", "-2\t/tmp/a.png"] {
            XCTAssertNil(ReaderProtocol.parseRequest(line), line)
        }
    }
}

/// Pipe reads arrive in arbitrary chunks.
final class LineBufferTests: XCTestCase {

    func testAPartialLineWaitsForItsEnd() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("rea".utf8)), [])
        XCTAssertEqual(buffer.append(Data("dy\n1\tok\t".utf8)), ["ready"])
        XCTAssertEqual(buffer.append(Data("QQ==\n2\tfail\n".utf8)), ["1\tok\tQQ==", "2\tfail"])
    }

    /// A multi-byte character split across two reads must not be mangled.
    func testACharacterSplitAcrossChunksSurvives() {
        var buffer = LineBuffer()
        let bytes = Array("é\n".utf8)
        XCTAssertEqual(buffer.append(Data(bytes[..<1])), [])
        XCTAssertEqual(buffer.append(Data(bytes[1...])), ["é"])
    }
}

final class TextCaptureStringsTests: XCTestCase {

    func testCountsWords() {
        XCTAssertEqual(TextCaptureStrings.copied("Bonjour, l'été à Paris"), "Copied 4 words")
    }

    func testSingular() {
        XCTAssertEqual(TextCaptureStrings.copied("ScreenHere"), "Copied 1 word")
    }

    func testNothingFound() {
        XCTAssertEqual(TextCaptureStrings.copied("  \n"), "No text found")
    }
}
