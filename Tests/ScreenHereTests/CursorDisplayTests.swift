import CoreGraphics
import XCTest
@testable import ScreenHere

/// Display layout of the machine this was designed on, in CoreGraphics
/// coordinates (origin top-left). Index in the array is the order
/// `CGGetActiveDisplayList` returns, which is exactly what `-D` indexes.
private enum Layout {
    /// External MSI MD271UL, the main display, at the origin.
    static let external = DisplayInfo(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    /// Built-in Retina display, placed to its right.
    static let builtIn = DisplayInfo(id: 1, bounds: CGRect(x: 2560, y: 0, width: 1680, height: 1050))
    static let both = [external, builtIn]
}

final class CursorDisplayTests: XCTestCase {

    func testPointerOnMainDisplayResolvesToD1() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 100, y: 100), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 1)
    }

    func testPointerOnSecondaryDisplayResolvesToD2() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 3000, y: 500), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 2)
    }

    /// The seam between the two displays belongs to the display whose bounds
    /// start there — CGRect.contains is inclusive of minX, exclusive of maxX.
    func testPointerOnTheSeamBelongsToTheDisplayItStarts() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 2560, y: 0), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 2)
    }

    func testPointerOutsideEveryDisplayFallsBackToMain() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 99_999, y: 99_999), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 1)
    }

    /// The main display is not always first in the list; the fallback must
    /// resolve by identifier, not by position.
    func testFallbackFindsMainDisplayWhereverItSitsInTheList() {
        let reordered = [Layout.builtIn, Layout.external]
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: -5000, y: 0), in: reordered, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 2)
    }

    func testSingleDisplaySetupAlwaysResolvesToD1() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 400, y: 400), in: [Layout.external], mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 1)
    }

    /// Mirrored displays share identical bounds. `screencapture` addresses a
    /// mirror set through its first member, which is what list order gives us.
    func testMirroredDisplaysResolveToTheFirstOfTheSet() {
        let mirrorA = DisplayInfo(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let mirrorB = DisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 800, y: 600), in: [mirrorA, mirrorB], mainDisplayID: mirrorA.id)
        XCTAssertEqual(index, 1)
    }

    /// Unplugging a display renumbers every index. Because the index is derived
    /// from the display list on each call and never cached, the pointer keeps
    /// resolving to the right screen across a topology change.
    func testIndexFollowsATopologyChange() {
        let before = CursorDisplay.captureIndex(
            for: CGPoint(x: 3000, y: 500), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(before, 2)

        // External display unplugged: the built-in one is all that is left.
        let after = CursorDisplay.captureIndex(
            for: CGPoint(x: 3000, y: 500), in: [Layout.builtIn], mainDisplayID: Layout.builtIn.id)
        XCTAssertEqual(after, 1)
    }

    /// A capture index is meaningless if we cannot enumerate displays; the
    /// caller must still receive a usable value rather than 0 or a crash.
    func testEmptyDisplayListStillYieldsAValidIndex() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 0, y: 0), in: [], mainDisplayID: 0)
        XCTAssertEqual(index, 1)
    }
}
