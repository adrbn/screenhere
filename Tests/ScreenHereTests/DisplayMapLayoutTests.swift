import CoreGraphics
import XCTest
@testable import ScreenHere

/// The panel draws a small live map of the displays. The arrangement has to
/// survive being squeezed into a fixed box: same relative positions, same
/// aspect ratio, and the pointer landing inside the display it is really on.
final class DisplayMapLayoutTests: XCTestCase {

    private let canvas = CGSize(width: 240, height: 120)

    /// The real layout of the machine this was built on: a 2560×1440 main
    /// display with a 1680×1050 laptop screen to its right.
    private let arrangement = [
        CGRect(x: 0, y: 0, width: 2560, height: 1440),
        CGRect(x: 2560, y: 0, width: 1680, height: 1050),
    ]

    func testEveryDisplayLandsInsideTheCanvas() {
        let fitted = DisplayMapLayout.fit(displays: arrangement, pointer: nil,
                                          into: canvas, padding: 6)
        XCTAssertEqual(fitted.rects.count, 2)
        for r in fitted.rects {
            XCTAssertGreaterThanOrEqual(r.minX, 0)
            XCTAssertGreaterThanOrEqual(r.minY, 0)
            XCTAssertLessThanOrEqual(r.maxX, canvas.width + 0.01)
            XCTAssertLessThanOrEqual(r.maxY, canvas.height + 0.01)
        }
    }

    func testRelativePositionsArePreserved() {
        let fitted = DisplayMapLayout.fit(displays: arrangement, pointer: nil,
                                          into: canvas, padding: 6)
        XCTAssertLessThan(fitted.rects[0].minX, fitted.rects[1].minX,
                          "the left display must stay on the left")
        XCTAssertGreaterThan(fitted.rects[0].height, fitted.rects[1].height,
                             "the taller display must stay taller")
    }

    /// A wide arrangement squeezed into a squarer box must letterbox rather
    /// than stretch, or the map would misrepresent the geometry.
    func testAspectRatioIsPreserved() {
        let fitted = DisplayMapLayout.fit(displays: arrangement, pointer: nil,
                                          into: canvas, padding: 0)
        let source = arrangement[0]
        let drawn = fitted.rects[0]
        XCTAssertEqual(drawn.width / drawn.height, source.width / source.height, accuracy: 0.01)
    }

    /// A lone display fills the padded box on whichever axis constrains it, and
    /// is centred on the other. Here 1000×500 (ratio 2.0) inside a 228×108 box
    /// (ratio 2.11) is height-constrained, so it must not touch the sides.
    func testSingleDisplayFillsTheConstrainingAxisAndCentresOnTheOther() {
        let fitted = DisplayMapLayout.fit(displays: [CGRect(x: 0, y: 0, width: 1000, height: 500)],
                                          pointer: nil, into: canvas, padding: 6)
        let r = fitted.rects[0]
        XCTAssertEqual(r.height, canvas.height - 12, accuracy: 0.01)
        XCTAssertEqual(r.width, 216, accuracy: 0.01)
        XCTAssertEqual(r.midX, canvas.width / 2, accuracy: 0.01)
    }

    /// The mirror case, so the axis choice is pinned in both directions.
    func testATallArrangementIsWidthConstrained() {
        let fitted = DisplayMapLayout.fit(displays: [CGRect(x: 0, y: 0, width: 100, height: 1000)],
                                          pointer: nil, into: canvas, padding: 6)
        let r = fitted.rects[0]
        XCTAssertEqual(r.height, canvas.height - 12, accuracy: 0.01)
        XCTAssertEqual(r.midY, canvas.height / 2, accuracy: 0.01)
    }

    func testPointerLandsInsideTheDisplayItIsOn() {
        // Middle of the second display.
        let point = CGPoint(x: 2560 + 840, y: 525)
        let fitted = DisplayMapLayout.fit(displays: arrangement, pointer: point,
                                          into: canvas, padding: 6)
        let mapped = try? XCTUnwrap(fitted.pointer)
        XCTAssertNotNil(mapped)
        XCTAssertTrue(fitted.rects[1].insetBy(dx: -0.5, dy: -0.5).contains(mapped!),
                      "\(mapped!) should sit inside \(fitted.rects[1])")
    }

    func testNoDisplaysYieldsNothingRatherThanACrash() {
        let fitted = DisplayMapLayout.fit(displays: [], pointer: CGPoint(x: 5, y: 5),
                                          into: canvas, padding: 6)
        XCTAssertTrue(fitted.rects.isEmpty)
        XCTAssertNil(fitted.pointer)
    }

    /// A zero-sized canvas can happen for one layout pass before SwiftUI knows
    /// the real size; it must not produce NaNs that poison the drawing.
    func testDegenerateCanvasProducesFiniteRects() {
        let fitted = DisplayMapLayout.fit(displays: arrangement, pointer: nil,
                                          into: .zero, padding: 6)
        for r in fitted.rects {
            XCTAssertTrue(r.origin.x.isFinite && r.origin.y.isFinite)
            XCTAssertTrue(r.width.isFinite && r.height.isFinite)
        }
    }
}
