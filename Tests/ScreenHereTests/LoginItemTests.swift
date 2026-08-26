import XCTest
@testable import ScreenHere

/// ScreenHere is only useful while it runs. A Mac that restarts without it as a
/// login item is left in the worst of both worlds: the system shortcut is still
/// disabled in preferences, and nothing is holding it — so ⇧⌘3 does nothing at
/// all rather than falling back to macOS behaviour. Hence a one-time offer.
final class LoginItemTests: XCTestCase {

    func testOffersOnFirstLaunchWhenNotAlreadyALoginItem() {
        XCTAssertTrue(LoginItem.shouldOffer(hasOffered: false, isAlreadyEnabled: false))
    }

    func testNeverOffersTwice() {
        XCTAssertFalse(LoginItem.shouldOffer(hasOffered: true, isAlreadyEnabled: false))
    }

    /// Nothing to ask for when the user already registered it — including the
    /// case where they enabled it from the menu before the offer ever fired.
    func testDoesNotOfferWhenAlreadyEnabled() {
        XCTAssertFalse(LoginItem.shouldOffer(hasOffered: false, isAlreadyEnabled: true))
        XCTAssertFalse(LoginItem.shouldOffer(hasOffered: true, isAlreadyEnabled: true))
    }
}
