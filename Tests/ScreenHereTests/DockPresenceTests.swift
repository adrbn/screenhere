import AppKit
import XCTest
@testable import ScreenHere

@MainActor
final class DockPresenceTests: XCTestCase {
    private var policy: NSApplication.ActivationPolicy = .accessory
    private var activations = 0

    private func make() -> DockPresence {
        DockPresence(policy: { self.policy },
                     setPolicy: { self.policy = $0 },
                     activate: { self.activations += 1 })
    }

    func testComingToFrontTakesADockTileAndActivates() {
        let dock = make()
        dock.comeToFront()
        XCTAssertEqual(policy, .regular)
        XCTAssertEqual(activations, 1)
    }

    /// Once the window that needed it is gone, the Dock tile goes too.
    func testSteppingBackGivesTheDockTileBack() {
        let dock = make()
        dock.comeToFront()
        dock.stepBack()
        XCTAssertEqual(policy, .accessory)
    }

    /// An update checked while the greeting is still up: the first window to
    /// close must not take the Dock tile away from the one still open, and
    /// what it steps back to is still where ScreenHere started.
    func testTheDockTileStaysUntilTheLastWindowIsGone() {
        let dock = make()
        dock.comeToFront()
        dock.comeToFront()
        dock.stepBack()
        XCTAssertEqual(policy, .regular)
        XCTAssertEqual(activations, 2)
        dock.stepBack()
        XCTAssertEqual(policy, .accessory)
    }

    func testSteppingBackMoreOftenThanComingToFrontChangesNothing() {
        let dock = make()
        dock.comeToFront()
        dock.stepBack()
        dock.stepBack()
        XCTAssertEqual(policy, .accessory)
        dock.comeToFront()
        dock.stepBack()
        XCTAssertEqual(policy, .accessory)
    }

    func testSteppingBackWithoutComingToFrontChangesNothing() {
        policy = .regular
        make().stepBack()
        XCTAssertEqual(policy, .regular)
    }
}
