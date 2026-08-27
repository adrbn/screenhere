import CoreGraphics
import XCTest
@testable import ScreenHere

/// The preview belongs on the display that was captured. That mapping — from
/// the `screencapture -D<n>` index back to a display — is the whole feature.
final class PreviewCoordinatorTests: XCTestCase {

    private let arrangement = [
        DisplayInfo(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
        DisplayInfo(id: 1, bounds: CGRect(x: 2560, y: 0, width: 1680, height: 1050)),
    ]

    /// `-D` is 1-based over CGGetActiveDisplayList, so -D2 is the second entry,
    /// whose identifier here is deliberately the lower number: an off-by-one
    /// would silently put the preview on the wrong screen and still look sane.
    func testTheIndexMapsToTheDisplayThatWasCaptured() {
        XCTAssertEqual(PreviewCoordinator.displayID(forCaptureIndex: 1, among: arrangement), 2)
        XCTAssertEqual(PreviewCoordinator.displayID(forCaptureIndex: 2, among: arrangement), 1)
    }

    /// A display unplugged between the capture and the preview: fall back
    /// rather than show it somewhere arbitrary.
    func testAnIndexBeyondTheArrangementYieldsNothing() {
        XCTAssertNil(PreviewCoordinator.displayID(forCaptureIndex: 3, among: arrangement))
        XCTAssertNil(PreviewCoordinator.displayID(forCaptureIndex: 0, among: arrangement))
        XCTAssertNil(PreviewCoordinator.displayID(forCaptureIndex: 1, among: []))
    }
}
