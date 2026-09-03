import XCTest
@testable import ScreenHere

/// Two one-time questions asked back to back is nagging, and hiding them both
/// is how the capture preview went unfound. So they are asked together, once.
final class FirstRunTests: XCTestCase {

    func testAsksWhenNeitherQuestionHasBeenPut() {
        XCTAssertTrue(FirstRun.shouldGreet(offeredLogin: false, offeredPreview: false,
                                           loginIsOn: false, previewIsOn: false))
    }

    /// Someone who already answered both — an existing user updating — must not
    /// be greeted as if they were new.
    func testDoesNotAskAgainOnceBothHaveBeenAnswered() {
        XCTAssertFalse(FirstRun.shouldGreet(offeredLogin: true, offeredPreview: true,
                                            loginIsOn: false, previewIsOn: false))
    }

    /// Updating from a version that only ever asked about the login item: the
    /// remaining question is still worth putting.
    func testStillAsksWhenOnlyOneQuestionWasEverPut() {
        XCTAssertTrue(FirstRun.shouldGreet(offeredLogin: true, offeredPreview: false,
                                           loginIsOn: true, previewIsOn: false))
    }

    /// Nothing left to offer: both settings are already on, however they got
    /// there.
    func testDoesNotAskAboutSettingsAlreadyOn() {
        XCTAssertFalse(FirstRun.shouldGreet(offeredLogin: false, offeredPreview: false,
                                            loginIsOn: true, previewIsOn: true))
    }

    /// Launch at Login is pre-ticked: without it a restart leaves ⇧⌘3 doing
    /// nothing at all. The preview is not, because it switches off a setting
    /// that belongs to the user.
    func testOnlyTheShortcutSavingOptionIsPreselected() {
        XCTAssertTrue(FirstRun.defaultLoginChoice)
        XCTAssertFalse(FirstRun.defaultPreviewChoice)
    }
}
