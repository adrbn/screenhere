import XCTest
@testable import ScreenHere

/// A pasteboard whose contents the test controls.
final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var string: String?
    var data: [String: Data] = [:]
    private(set) var stringReads = 0
    private(set) var dataReads = 0

    func currentTypes() -> [String] { types }
    func currentString() -> String? {
        stringReads += 1
        return string
    }
    func currentData(forType type: String) -> Data? {
        dataReads += 1
        return data[type]
    }

    func copy(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        changeCount += 1
        self.types = types
        string = text
        data = [:]
    }

    func copyImage(_ bytes: Data, type: String = "public.png", extraTypes: [String] = [],
                   text: String? = nil) {
        changeCount += 1
        types = [type] + extraTypes
        string = text
        data = [type: bytes]
    }
}

@MainActor
final class ClipboardWatcherTests: XCTestCase {

    private var recorded: [String] = []
    private var copies: [Copied] = []

    private func watcher(_ pasteboard: FakePasteboard) -> ClipboardWatcher {
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApp: { "Notes" })
        watcher.onCopy = { [unowned self] copied, _ in
            copies.append(copied)
            if case .text(let text) = copied { recorded.append(text) }
        }
        watcher.prime()
        return watcher
    }

    override func setUp() {
        recorded = []
        copies = []
    }

    /// Whatever was on the clipboard before history was turned on is not a
    /// copy the user made while it was on.
    func testWhatWasAlreadyThereIsNotRecorded() {
        let pb = FakePasteboard()
        pb.copy("old")
        let w = watcher(pb)
        w.poll()
        XCTAssertEqual(recorded, [])
    }

    func testANewCopyIsRecordedOnce() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copy("hello")
        w.poll()
        w.poll()
        XCTAssertEqual(recorded, ["hello"])
    }

    /// Nothing changed, so nothing is read — reading content is what the
    /// system's paste-access privacy watches, and it is not free either.
    func testAnUnchangedPasteboardIsNeverRead() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        for _ in 0..<5 { w.poll() }
        XCTAssertEqual(pb.stringReads, 0)
    }

    func testPasswordManagerCopiesAreNotRecorded() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        w.poll()
        XCTAssertEqual(recorded, [])
        XCTAssertEqual(pb.stringReads, 0, "a concealed item must not even be read")
    }

    /// ScreenHere's own writes (copying back from history, OCR) are added to
    /// the history directly; the watcher must not add them a second time.
    func testOwnWritesAreSkipped() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copy("from history")
        w.ignore(changeCount: pb.changeCount)
        w.poll()
        XCTAssertEqual(recorded, [])
    }

    func testACopiedImageIsReported() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copyImage(Data([1, 2, 3]), type: "public.png", extraTypes: ["public.tiff"])
        w.poll()
        XCTAssertEqual(copies, [.image(Data([1, 2, 3]), type: "public.png")])
    }

    /// A spreadsheet or rich-text selection carries a picture of itself too;
    /// the words are what the user copied.
    func testTextWinsOverItsOwnPicture() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copyImage(Data([9]), type: "public.tiff", extraTypes: ["public.utf8-plain-text"],
                     text: "A1\tB1")
        w.poll()
        XCTAssertEqual(copies, [.text("A1\tB1")])
        XCTAssertEqual(pb.dataReads, 0, "the picture is not even read")
    }

    /// Browsers' "Copy Image" adds the image's address as text.
    func testAnImageWithOnlyItsLinkAsTextIsAnImage() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copyImage(Data([7]), type: "public.tiff", extraTypes: ["public.utf8-plain-text"],
                     text: "https://example.com/cat.jpg")
        w.poll()
        XCTAssertEqual(copies, [.image(Data([7]), type: "public.tiff")])
    }

    /// Copying a file in Finder puts its icon on the pasteboard; that icon is
    /// not a picture the user copied.
    func testAFinderFileCopyIsNotAnImage() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copyImage(Data([5]), type: "public.tiff", extraTypes: ["public.file-url"])
        w.poll()
        XCTAssertEqual(copies, [])
    }

    func testAConcealedImageIsNotRead() {
        let pb = FakePasteboard()
        let w = watcher(pb)
        pb.copyImage(Data([4]), type: "public.png", extraTypes: ["org.nspasteboard.ConcealedType"])
        w.poll()
        XCTAssertEqual(copies, [])
        XCTAssertEqual(pb.dataReads, 0)
    }
}

final class PasteboardFilterTests: XCTestCase {

    func testPlainTextIsRecorded() {
        XCTAssertEqual(PasteboardFilter.kind(of: ["public.utf8-plain-text"]), .text)
    }

    func testMarkedSecretsAreNot() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"] {
            XCTAssertNil(PasteboardFilter.kind(of: ["public.utf8-plain-text", marker]), marker)
            XCTAssertNil(PasteboardFilter.kind(of: ["public.png", marker]), marker)
        }
    }

    func testImagesAreRecorded() {
        XCTAssertEqual(PasteboardFilter.kind(of: ["public.tiff", "public.png"]), .image(type: "public.png"))
        XCTAssertEqual(PasteboardFilter.kind(of: ["public.jpeg"]), .image(type: "public.jpeg"))
    }

    func testUnknownContentIsNot() {
        XCTAssertNil(PasteboardFilter.kind(of: ["com.apple.pdfkit.annotation"]))
    }

    func testOnlyASingleLinkCountsAsALink() {
        XCTAssertTrue(PasteboardFilter.isLink("https://example.com/a.png"))
        XCTAssertFalse(PasteboardFilter.isLink("see https://example.com"))
        XCTAssertFalse(PasteboardFilter.isLink("plain words"))
    }
}
