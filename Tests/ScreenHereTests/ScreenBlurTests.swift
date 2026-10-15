import XCTest
@testable import ScreenHere

/// Which screens get frosted, and when: everything but the one the pointer is
/// on, a moment after it leaves.
@MainActor
final class ScreenBlurTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let delay: TimeInterval = 1.5

    private let left = DisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let right = DisplayInfo(id: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
    private let third = DisplayInfo(id: 3, bounds: CGRect(x: 3840, y: 0, width: 1920, height: 1080))

    private func covered(_ displays: [DisplayInfo], pointer: CGPoint,
                         lastSeen: [CGDirectDisplayID: Date] = [:],
                         at moment: Date? = nil) -> Set<CGDirectDisplayID> {
        ScreenBlur.covered(displays: displays, pointer: pointer, lastSeen: lastSeen,
                           now: moment ?? now, delay: delay)
    }

    /// One display is the screen you are on; there is nothing beside it.
    func testASingleDisplayIsNeverFrosted() {
        XCTAssertTrue(covered([left], pointer: CGPoint(x: 10, y: 10)).isEmpty)
    }

    /// A screen never visited is frosted at once: at launch, only the one
    /// under the pointer is clear.
    func testEveryOtherScreenStartsFrosted() {
        XCTAssertEqual(covered([left, right, third], pointer: CGPoint(x: 10, y: 10)), [2, 3])
    }

    /// The screen under the pointer is clear even when it was left a moment
    /// ago and came back.
    func testTheScreenUnderThePointerIsClear() {
        let seen: [CGDirectDisplayID: Date] = [1: now.addingTimeInterval(-60), 2: now]
        XCTAssertEqual(covered([left, right], pointer: CGPoint(x: 2000, y: 10), lastSeen: seen), [1])
    }

    /// Glancing at the other screen must not frost the one just left.
    func testTheScreenJustLeftIsStillClear() {
        let seen: [CGDirectDisplayID: Date] = [1: now, 2: now.addingTimeInterval(-10)]
        // The pointer has just arrived on the right: the left one keeps its
        // picture a moment longer.
        XCTAssertEqual(covered([left, right], pointer: CGPoint(x: 2000, y: 10), lastSeen: seen), [])
    }

    func testTheScreenLeftLongEnoughIsFrosted() {
        let seen: [CGDirectDisplayID: Date] = [1: now.addingTimeInterval(-delay)]
        XCTAssertEqual(covered([left, right], pointer: CGPoint(x: 2000, y: 10), lastSeen: seen), [1])
    }

    /// Between two displays — a gap in an odd arrangement — frosting the
    /// screen being used would be worse than frosting nothing.
    func testNothingIsFrostedWhenThePointerIsOnNoDisplay() {
        XCTAssertTrue(covered([left, right], pointer: CGPoint(x: -500, y: 10)).isEmpty)
    }
}
