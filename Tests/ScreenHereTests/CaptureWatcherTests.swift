import AppKit
import XCTest
@testable import ScreenHere

/// With the destination set to the clipboard there is no file to watch, so a
/// capture is recognised by what lands on the pasteboard. Anything that copies
/// an image would otherwise trigger a preview, so the shape of the payload has
/// to carry the decision.
final class CaptureWatcherTests: XCTestCase {

    private func types(_ raw: [String]) -> [NSPasteboard.PasteboardType] {
        raw.map(NSPasteboard.PasteboardType.init(rawValue:))
    }

    /// A screenshot arrives as bare image data and nothing else.
    func testBareImageDataLooksLikeACapture() {
        XCTAssertTrue(CaptureWatcher.looksLikeCapture(types: types(["public.tiff", "public.png"])))
        XCTAssertTrue(CaptureWatcher.looksLikeCapture(types: types(["public.png"])))
    }

    /// Copying an image from a web page carries its markup and address with it.
    func testImageCopiedFromAPageIsNotACapture() {
        XCTAssertFalse(CaptureWatcher.looksLikeCapture(
            types: types(["public.png", "public.html", "public.url"])))
    }

    /// Copying a file in the Finder puts a file URL on the board.
    func testCopiedFileIsNotACapture() {
        XCTAssertFalse(CaptureWatcher.looksLikeCapture(
            types: types(["public.tiff", "public.file-url"])))
    }

    func testTextIsNotACapture() {
        XCTAssertFalse(CaptureWatcher.looksLikeCapture(types: types(["public.utf8-plain-text"])))
        XCTAssertFalse(CaptureWatcher.looksLikeCapture(types: []))
    }

    /// Universal Clipboard marks its payload, and an image arriving from an
    /// iPhone is not a capture taken on this Mac.
    func testAnImageFromAnotherDeviceIsNotACapture() {
        XCTAssertFalse(CaptureWatcher.looksLikeCapture(
            types: types(["public.png", "com.apple.is-remote-clipboard"])))
    }
}
