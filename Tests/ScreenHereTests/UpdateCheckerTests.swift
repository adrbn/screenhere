import XCTest
@testable import ScreenHere

final class UpdateCheckerTests: XCTestCase {

    func testIsNewerComparesSemanticComponents() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    }

    func testIsNewerToleratesVaryingComponentCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }

    func testEvaluateReportsUpdateAvailable() {
        let data = #"{"tag_name":"v1.2.0"}"#.data(using: .utf8)
        let outcome = UpdateChecker.evaluate(current: "1.0.0", data: data, status: 200, error: nil)
        XCTAssertEqual(outcome, .updateAvailable(latest: "1.2.0", current: "1.0.0"))
    }

    func testEvaluateReportsUpToDate() {
        let data = #"{"tag_name":"v1.0.0"}"#.data(using: .utf8)
        let outcome = UpdateChecker.evaluate(current: "1.0.0", data: data, status: 200, error: nil)
        XCTAssertEqual(outcome, .upToDate(current: "1.0.0"))
    }

    func testEvaluateReportsNoReleasesOn404() {
        let outcome = UpdateChecker.evaluate(current: "1.0.0", data: nil, status: 404, error: nil)
        XCTAssertEqual(outcome, .noReleases)
    }

    func testEvaluateReportsFailureOnOtherStatus() {
        let outcome = UpdateChecker.evaluate(current: "1.0.0", data: nil, status: 500, error: nil)
        XCTAssertEqual(outcome, .failed("GitHub returned HTTP 500."))
    }

    func testEvaluateReportsFailureOnMalformedJSON() {
        let data = "not json".data(using: .utf8)
        let outcome = UpdateChecker.evaluate(current: "1.0.0", data: data, status: 200, error: nil)
        XCTAssertEqual(outcome, .failed("Unexpected response from GitHub."))
    }
}
