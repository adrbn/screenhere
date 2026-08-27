import CoreGraphics
import XCTest
@testable import ScreenHere

/// The map highlights `activeDisplayIndex` and names the display it points at.
/// `screencapture` numbers displays from one and an array indexes from zero,
/// and losing that conversion highlights the wrong screen while the caption
/// reads "unknown display" — visible on every Mac, and caught by nothing until
/// a documentation shot happened to print the number.
@MainActor
final class PanelModelTests: XCTestCase {

    private let external = DisplayInfo(id: 90, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    private let laptop = DisplayInfo(id: 91, bounds: CGRect(x: 2560, y: 0, width: 1680, height: 1050))

    private func model(pointer: CGPoint, displays: [DisplayInfo]) -> PanelModel {
        let takeover = TakeoverController(
            store: FakeSymbolicHotkeyStore(), binding: FakeHotkeyBinding(),
            defaults: .makeTransient(), capture: { _, _ in }, currentDisplayIndex: { 1 })
        let model = PanelModel(takeover: takeover)
        model.sampleDisplays = { displays }
        model.samplePointer = { pointer }
        model.posedNames = [90: "Studio", 91: "Built-in"]
        model.posedState = (permission: true, isOn: true)
        model.refresh()
        return model
    }

    func testTheFirstDisplayIsIndexZero() {
        let m = model(pointer: CGPoint(x: 100, y: 100), displays: [external, laptop])
        XCTAssertEqual(m.activeDisplayIndex, 0)
        XCTAssertEqual(m.activeDisplayName, "Studio")
    }

    /// The case the off-by-one broke: the pointer on the last display fell off
    /// the end of the array.
    func testTheLastDisplayIsInRange() {
        let m = model(pointer: CGPoint(x: 3300, y: 500), displays: [external, laptop])
        XCTAssertEqual(m.activeDisplayIndex, 1)
        XCTAssertEqual(m.activeDisplayName, "Built-in")
    }

    func testASingleDisplayIsAlwaysIndexZero() {
        let m = model(pointer: CGPoint(x: 400, y: 400), displays: [laptop])
        XCTAssertEqual(m.activeDisplayIndex, 0)
        XCTAssertEqual(m.activeDisplayName, "Built-in")
    }

    /// Whatever the arrangement, the index must address a real display.
    func testTheIndexAlwaysAddressesADisplay() {
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 4239, y: 1049), CGPoint(x: -900, y: -900)] {
            let m = model(pointer: point, displays: [external, laptop])
            XCTAssertTrue((0..<2).contains(m.activeDisplayIndex),
                          "index \(m.activeDisplayIndex) out of range for \(point)")
        }
    }
}
