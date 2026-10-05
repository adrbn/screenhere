import AppKit
import XCTest
@testable import ScreenHere

/// The fast engine's throwaway process: bytes in, text out. Only the boundary
/// is checked here — a test that read a real capture would run Vision in the
/// test process, which is what this service exists to avoid.
final class FastReadServiceTests: XCTestCase {

    func testNoCaptureCannotBeRead() {
        XCTAssertNil(FastReadService.read(nil))
    }

    func testBytesThatAreNotAnImageCannotBeRead() {
        XCTAssertNil(FastReadService.read(Data("not an image".utf8)))
    }

    func testAnImageDecodesBeforeItIsRead() {
        XCTAssertNotNil(TextRecognizer.image(from: Self.png()))
    }

    private static func png() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
    }
}
