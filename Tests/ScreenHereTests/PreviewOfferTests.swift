import XCTest
@testable import ScreenHere

/// The preview lands on the captured screen only if the user knows the option
/// exists. The one person outside this repo who has used ScreenHere reported
/// the macOS preview appearing on the wrong display — the exact thing the
/// option fixes — without ever finding the row. An option nobody discovers is
/// not really shipped. So it is offered once, the same way Launch at Login is,
/// rather than switched on behind their back: it turns off a macOS setting,
/// and that is theirs to decide.
final class PreviewOfferTests: XCTestCase {

    func testOffersOnceWhenTheOptionHasNeverBeenConsidered() {
        XCTAssertTrue(PreviewOffer.shouldOffer(hasOffered: false, isAlreadyOn: false))
    }

    func testNeverOffersTwice() {
        XCTAssertFalse(PreviewOffer.shouldOffer(hasOffered: true, isAlreadyOn: false))
    }

    /// Nothing to ask when they already found and enabled it themselves.
    func testDoesNotOfferWhatIsAlreadyOn() {
        XCTAssertFalse(PreviewOffer.shouldOffer(hasOffered: false, isAlreadyOn: true))
        XCTAssertFalse(PreviewOffer.shouldOffer(hasOffered: true, isAlreadyOn: true))
    }
}
