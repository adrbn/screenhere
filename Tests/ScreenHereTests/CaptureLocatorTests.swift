import XCTest
@testable import ScreenHere

/// `screencapture -p` picks the filename itself, so the app finds the image it
/// just produced by looking for what appeared in the destination folder.
final class CaptureLocatorTests: XCTestCase {

    private func file(_ name: String, _ secondsAgo: TimeInterval) -> CaptureLocator.Candidate {
        CaptureLocator.Candidate(url: URL(fileURLWithPath: "/tmp/\(name)"),
                                 created: Date(timeIntervalSinceNow: -secondsAgo))
    }

    func testPicksTheFileThatAppearedAfterTheCapture() {
        let started = Date(timeIntervalSinceNow: -2)
        let found = CaptureLocator.produced(
            among: [file("old.png", 600), file("fresh.png", 1)],
            after: started, within: 5)
        XCTAssertEqual(found?.lastPathComponent, "fresh.png")
    }

    /// A folder full of older screenshots must not be mistaken for this one.
    func testIgnoresFilesOlderThanTheCapture() {
        let started = Date(timeIntervalSinceNow: -2)
        let found = CaptureLocator.produced(
            among: [file("old.png", 600), file("older.png", 9000)],
            after: started, within: 5)
        XCTAssertNil(found)
    }

    /// Two captures in quick succession: the newest is this one.
    func testPicksTheNewestWhenSeveralAreFresh() {
        let started = Date(timeIntervalSinceNow: -3)
        let found = CaptureLocator.produced(
            among: [file("first.png", 2.5), file("second.png", 0.4)],
            after: started, within: 5)
        XCTAssertEqual(found?.lastPathComponent, "second.png")
    }

    /// A file that arrives long after we asked is somebody else's.
    func testIgnoresFilesBeyondTheWindow() {
        let started = Date(timeIntervalSinceNow: -60)
        let found = CaptureLocator.produced(
            among: [file("late.png", 1)], after: started, within: 5)
        XCTAssertNil(found)
    }

    func testEmptyFolderYieldsNothing() {
        XCTAssertNil(CaptureLocator.produced(among: [], after: Date(), within: 5))
    }
}
