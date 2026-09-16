import XCTest
@testable import ScreenHere

final class ClipboardHistoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNewestComesFirst() {
        let history = ClipboardHistory.empty
            .adding("first", source: nil, at: t0)
            .adding("second", source: nil, at: t0.addingTimeInterval(1))
        XCTAssertEqual(history.items.map(\.text), ["second", "first"])
    }

    /// Adding returns a new history; the original is untouched.
    func testAddingDoesNotMutateTheOriginal() {
        let original = ClipboardHistory.empty.adding("kept", source: nil, at: t0)
        _ = original.adding("other", source: nil, at: t0)
        XCTAssertEqual(original.items.map(\.text), ["kept"])
    }

    /// Copying the same thing twice should not fill the list with duplicates;
    /// it moves back to the top instead.
    func testCopyingAgainMovesToTheTop() {
        let history = ClipboardHistory.empty
            .adding("a", source: nil, at: t0)
            .adding("b", source: nil, at: t0.addingTimeInterval(1))
            .adding("a", source: "Safari", at: t0.addingTimeInterval(2))
        XCTAssertEqual(history.items.map(\.text), ["a", "b"])
        XCTAssertEqual(history.items.first?.source, "Safari")
        XCTAssertEqual(history.items.first?.date, t0.addingTimeInterval(2))
    }

    func testBlankTextIsIgnored() {
        let history = ClipboardHistory.empty
            .adding("   \n\t", source: nil, at: t0)
            .adding("", source: nil, at: t0)
        XCTAssertTrue(history.items.isEmpty)
    }

    /// A multi-megabyte copy would bloat the file and the list; it is skipped
    /// rather than truncated, because pasting a truncated copy back would
    /// silently lose data.
    func testOversizedTextIsSkippedNotTruncated() {
        let huge = String(repeating: "x", count: ClipboardHistory.maxLength + 1)
        let history = ClipboardHistory.empty.adding(huge, source: nil, at: t0)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testTheOldestFallOffPastCapacity() {
        var history = ClipboardHistory.empty
        for i in 0..<(ClipboardHistory.capacity + 5) {
            history = history.adding("item \(i)", source: nil, at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(history.items.count, ClipboardHistory.capacity)
        XCTAssertEqual(history.items.first?.text, "item \(ClipboardHistory.capacity + 4)")
        XCTAssertFalse(history.items.contains { $0.text == "item 0" })
    }

    func testRemovingOneItem() {
        let history = ClipboardHistory.empty
            .adding("a", source: nil, at: t0)
            .adding("b", source: nil, at: t0)
        let id = history.items[1].id
        XCTAssertEqual(history.removing(id).items.map(\.text), ["b"])
    }

    // MARK: - Search

    private var sample: ClipboardHistory {
        ClipboardHistory.empty
            .adding("Réunion lundi à 10h", source: "Mail", at: t0)
            .adding("https://github.com/adrbn/screenhere", source: "Safari", at: t0)
            .adding("git push origin main", source: "Terminal", at: t0)
    }

    func testAnEmptyQueryMatchesEverything() {
        XCTAssertEqual(sample.matching("  ").count, 3)
    }

    /// Typed without accents or capitals, still found.
    func testSearchIgnoresCaseAndAccents() {
        XCTAssertEqual(sample.matching("REUNION").map(\.source), ["Mail"])
    }

    /// Every word must appear, in any order.
    func testEveryWordMustMatch() {
        XCTAssertEqual(sample.matching("main push").map(\.source), ["Terminal"])
        XCTAssertTrue(sample.matching("push lundi").isEmpty)
    }

    // MARK: - Images

    private func image(_ digest: String, bytes: Int = 1_000) -> ClipImage {
        ClipImage(digest: digest, format: .png, width: 1920, height: 1080, byteCount: bytes)
    }

    func testImagesJoinTheListNewestFirst() {
        let history = ClipboardHistory.empty
            .adding("text", source: nil, at: t0)
            .adding(image: image("a"), source: "Preview", at: t0.addingTimeInterval(1))
        XCTAssertEqual(history.items.first?.image?.digest, "a")
        XCTAssertEqual(history.items.map(\.text), [nil, "text"])
    }

    /// The same picture copied twice is one entry, moved back to the top.
    func testTheSameImageAgainMovesToTheTop() {
        let history = ClipboardHistory.empty
            .adding(image: image("a"), source: nil, at: t0)
            .adding("b", source: nil, at: t0.addingTimeInterval(1))
            .adding(image: image("a"), source: "Safari", at: t0.addingTimeInterval(2))
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(history.items.first?.image?.digest, "a")
        XCTAssertEqual(history.items.first?.source, "Safari")
    }

    /// Screenshots weigh megabytes: past the budget the oldest pictures go,
    /// and the text around them stays.
    func testImagesPastTheBudgetDropOldestFirst() {
        let big = ClipboardHistory.maxImageBytes
        let fitting = ClipboardHistory.imageBudget / big
        var history = ClipboardHistory.empty
            .adding(image: image("i0", bytes: big), source: nil, at: t0)
            .adding("note", source: nil, at: t0.addingTimeInterval(1))
        for i in 1...fitting {
            history = history.adding(image: image("i\(i)", bytes: big), source: nil,
                                     at: t0.addingTimeInterval(Double(i + 1)))
        }
        XCTAssertEqual(history.imageDigests.count, fitting)
        XCTAssertFalse(history.imageDigests.contains("i0"))
        XCTAssertEqual(history.items.first?.image?.digest, "i\(fitting)")
        XCTAssertEqual(history.items.compactMap(\.text), ["note"])
    }

    /// A small old picture must not outlive a bigger, newer one just because
    /// it fits in what is left.
    func testNoOlderPictureSurvivesANewerOneDroppedForTheBudget() {
        let mb = 1024 * 1024
        let sizes = [("n6", 5), ("n5", 10), ("n4", 20), ("n3", 25), ("n2", 25), ("n1", 25)]
        var history = ClipboardHistory.empty
        for (i, (digest, size)) in sizes.enumerated() {
            history = history.adding(image: image(digest, bytes: size * mb), source: nil,
                                     at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(history.items.compactMap(\.image?.digest), ["n1", "n2", "n3", "n4"])
    }

    func testAnImageBiggerThanTheLimitIsSkipped() {
        let history = ClipboardHistory.empty
            .adding(image: image("huge", bytes: ClipboardHistory.maxImageBytes + 1), source: nil, at: t0)
        XCTAssertTrue(history.items.isEmpty)
    }

    /// Pictures have no words; "image" or the app they came from finds them.
    func testImagesAreFoundByKindAndSource() {
        let history = sample.adding(image: image("shot"), source: "ScreenHere", at: t0)
        XCTAssertEqual(history.matching("image").compactMap(\.image?.digest), ["shot"])
        XCTAssertEqual(history.matching("screenhere").map(\.text), [nil, "https://github.com/adrbn/screenhere"])
        XCTAssertTrue(history.matching("lundi").allSatisfy { $0.image == nil })
    }

    func testRemovingByPredicate() {
        let history = sample.adding(image: image("gone"), source: nil, at: t0)
        XCTAssertEqual(history.filtering { $0.image == nil }.items.count, 3)
    }

    /// History saved before pictures were kept stored text items flat; an
    /// update must read them rather than start the list over.
    func testReadsHistorySavedBeforeImages() throws {
        let legacy = """
        {"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"kept across the update",
        "date":1000000,"source":"Notes"}]}
        """
        let history = try JSONDecoder().decode(ClipboardHistory.self, from: Data(legacy.utf8))
        XCTAssertEqual(history.items.map(\.text), ["kept across the update"])
        XCTAssertEqual(history.items.first?.source, "Notes")
    }

    /// One unreadable entry — a torn write, a newer version's format — costs
    /// that entry, not the history around it, which the next save would
    /// otherwise overwrite with nothing.
    func testAnUnreadableItemDoesNotLoseTheRest() throws {
        let history = ClipboardHistory.empty
            .adding("older", source: nil, at: t0)
            .adding("newer", source: nil, at: t0.addingTimeInterval(1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var items = try XCTUnwrap(object["items"] as? [Any])
        items.insert(["id": "not a uuid"], at: 1)
        items.append(NSNull())
        items.append(42)
        object["items"] = items
        let damaged = try JSONSerialization.data(withJSONObject: object)
        let loaded = try JSONDecoder().decode(ClipboardHistory.self, from: damaged)
        XCTAssertEqual(loaded.items.compactMap(\.text), ["newer", "older"])
    }

    func testRoundTripsThroughJSON() throws {
        let history = sample.adding(image: image("json"), source: "Preview", at: t0)   // computed: each read mints new ids
        let data = try JSONEncoder().encode(history)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardHistory.self, from: data), history)
    }
}
