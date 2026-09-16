import XCTest
@testable import ScreenHere

final class ClipboardHistoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHereTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavesAndLoads() throws {
        let store = ClipboardHistoryStore(directory: directory)
        let history = ClipboardHistory.empty.adding("persisted", source: "Notes", at: Date())
        try store.save(history)
        XCTAssertEqual(store.load(), history)
    }

    func testAMissingFileIsAnEmptyHistory() {
        XCTAssertEqual(ClipboardHistoryStore(directory: directory).load(), .empty)
    }

    /// A damaged file must not crash the app or block new history.
    func testACorruptFileIsAnEmptyHistory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ClipboardHistoryStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .empty)
    }

    /// Everything the user copies lands in this file, so nobody else on the
    /// machine gets to read it.
    func testTheFileIsReadableByTheOwnerOnly() throws {
        let store = ClipboardHistoryStore(directory: directory)
        try store.save(ClipboardHistory.empty.adding("secret-ish", source: nil, at: Date()))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDeletingRemovesTheFile() throws {
        let store = ClipboardHistoryStore(directory: directory)
        try store.save(ClipboardHistory.empty.adding("x", source: nil, at: Date()))
        store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
