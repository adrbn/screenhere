import XCTest
@testable import ScreenHere

final class WindowUnderPointerTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let me: pid_t = 100

    private func window(_ id: CGWindowID, _ bounds: CGRect, layer: Int = 0,
                        alpha: Double = 1, owner: pid_t = 200) -> ListedWindow {
        ListedWindow(id: id, ownerPID: owner, layer: layer, alpha: alpha, bounds: bounds)
    }

    private func pick(_ point: CGPoint, _ windows: [ListedWindow]) -> CGWindowID? {
        WindowUnderPointer.pick(at: point, in: windows, displays: [display], ownPID: me)
    }

    func testPicksTheFrontmostWindowUnderThePointer() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 400, height: 300)),
                       window(2, CGRect(x: 100, y: 100, width: 800, height: 600))]
        XCTAssertEqual(pick(CGPoint(x: 200, y: 200), windows), 1)
        XCTAssertEqual(pick(CGPoint(x: 600, y: 500), windows), 2)
    }

    func testNothingUnderThePointerMeansNoWindow() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 400, height: 300))]
        XCTAssertNil(pick(CGPoint(x: 1000, y: 900), windows))
    }

    func testSkipsScreenHeresOwnWindows() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 400, height: 300), owner: me),
                       window(2, CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(pick(CGPoint(x: 10, y: 10), windows), 2)
    }

    func testSkipsInvisibleWindows() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 400, height: 300), alpha: 0),
                       window(2, CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(pick(CGPoint(x: 10, y: 10), windows), 2)
    }

    /// A tooltip or a resize handle is not what anyone means to capture.
    func testSkipsTinyWindows() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 30, height: 20)),
                       window(2, CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(pick(CGPoint(x: 10, y: 10), windows), 2)
    }

    /// The Dock, the menu bar or an open menu is in front of the window below
    /// it: the pointer is on that, so the capture falls back to the screen.
    func testAMenuOrTheDockInFrontMeansNoWindow() {
        let dock = window(1, CGRect(x: 0, y: 1000, width: 1920, height: 80), layer: 20)
        let menu = window(3, CGRect(x: 400, y: 900, width: 220, height: 180), layer: 101)
        let below = window(2, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertNil(pick(CGPoint(x: 500, y: 1040), [dock, below]))
        XCTAssertNil(pick(CGPoint(x: 500, y: 950), [menu, below]))
    }

    /// Picture in Picture, a utility panel or a note kept on top floats above
    /// the normal windows, but it is still a window someone means to capture.
    func testPicksAWindowFloatingAboveTheOthers() {
        let windows = [window(1, CGRect(x: 1500, y: 800, width: 400, height: 225), layer: 3),
                       window(2, CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        XCTAssertEqual(pick(CGPoint(x: 1600, y: 900), windows), 1)
    }

    /// Whatever sits behind the normal windows is never what the pointer is on.
    func testSkipsLayersBehindTheNormalWindows() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 800, height: 600), layer: -20)]
        XCTAssertNil(pick(CGPoint(x: 10, y: 10), windows))
        XCTAssertEqual(pick(CGPoint(x: 10, y: 10),
                            windows + [window(2, CGRect(x: 0, y: 0, width: 400, height: 300))]), 2)
    }

    /// Some utilities cover a whole display with a transparent layer. That is
    /// not what the pointer is on.
    func testLooksThroughOverlaysCoveringAWholeDisplay() {
        let windows = [window(1, display, layer: 2000),
                       window(2, CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(pick(CGPoint(x: 10, y: 10), windows), 2)
    }

    /// At times macOS draws the pointer itself in a small window at the top of
    /// everything, right where the pointer is. It is never what the pointer is on.
    func testLooksThroughThePointerItself() {
        let pointer = window(1, CGRect(x: 605, y: 400, width: 28, height: 40),
                             layer: Int(CGWindowLevelForKey(.cursorWindow)))
        let finder = window(2, CGRect(x: 380, y: 176, width: 920, height: 436))
        XCTAssertEqual(pick(CGPoint(x: 609, y: 404), [pointer, finder]), 2)
        XCTAssertNil(pick(CGPoint(x: 609, y: 404), [pointer]))
    }
}

final class WindowCaptureTests: XCTestCase {
    private var ran: [[String]] = []

    private func run(_ destination: CaptureDestination, window: CGWindowID?, display: Int = 1) {
        WindowCapture.run(destination: destination, window: { window },
                          displayIndex: { display }, runner: { self.ran.append($0) })
    }

    func testCapturesTheWindowUnderThePointer() {
        run(.userSettings, window: 42)
        XCTAssertEqual(ran, [CaptureRunner.arguments(destination: .userSettings, windowID: 42)])
    }

    /// With no window under the pointer, the press still captures something:
    /// the display, to the same place.
    func testFallsBackToTheDisplayWhenThereIsNoWindow() {
        run(.clipboard, window: nil, display: 2)
        XCTAssertEqual(ran, [CaptureRunner.arguments(destination: .clipboard, displayIndex: 2)])
    }
}
