import XCTest
@testable import ScreenHere

/// The ⇧⌘8 list's clear-all: asked in the footer, confirmed with a click only.
@MainActor
final class HistoryPickerModelTests: XCTestCase {

    private var model: HistoryPickerModel!
    private var chosen: [ClipItem] = []
    private var closed = 0
    private var cleared = 0

    override func setUp() {
        ClipboardController.shared.pose(ClipboardHistory.empty.adding("hello", source: nil, at: Date()),
                                        enabled: true)
        chosen = []
        closed = 0
        cleared = 0
        model = HistoryPickerModel(clipboard: .shared)
        model.onChoose = { [unowned self] in chosen.append($0) }
        model.onClose = { [unowned self] in closed += 1 }
        model.onClear = { [unowned self] in cleared += 1 }
    }

    override func tearDown() {
        ClipboardController.shared.pose(.empty, enabled: false)
    }

    func testClearingAsksFirst() {
        model.askToClear()
        XCTAssertTrue(model.confirmingClear)
        XCTAssertEqual(cleared, 0)
    }

    func testConfirmingClears() {
        model.askToClear()
        model.clearAll()
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(model.confirmingClear)
    }

    /// Return is how the list copies; it must never be what deletes everything.
    func testReturnNeverConfirms() {
        model.askToClear()
        model.submit()
        XCTAssertEqual(cleared, 0)
        XCTAssertTrue(chosen.isEmpty)
        XCTAssertTrue(model.confirmingClear)
    }

    func testEscapeCancelsTheQuestionBeforeClosing() {
        model.askToClear()
        model.cancel()
        XCTAssertFalse(model.confirmingClear)
        XCTAssertEqual(closed, 0)
        model.cancel()
        XCTAssertEqual(closed, 1)
    }

    func testReturnCopiesWhenNotAsking() {
        model.submit()
        XCTAssertEqual(chosen.compactMap(\.text), ["hello"])
    }
}
