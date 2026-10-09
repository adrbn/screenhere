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

    // MARK: Copied files

    private func files(_ paths: String...) -> [ClipFile] {
        paths.map { ClipFile(path: $0) }
    }

    func testCopiedFilesAreKeptAsOneItem() {
        let history = ClipboardHistory.empty
            .adding(files: files("/tmp/a.pdf", "/tmp/b.png"), source: "Finder", at: t0)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.items.first?.files?.map(\.name), ["a.pdf", "b.png"])
    }

    /// The same selection copied again moves back to the top; a different one
    /// is its own entry, even when the files overlap.
    func testCopyingTheSameFilesAgainMovesToTheTop() {
        let history = ClipboardHistory.empty
            .adding(files: files("/tmp/a.pdf"), source: nil, at: t0)
            .adding("text", source: nil, at: t0.addingTimeInterval(1))
            .adding(files: files("/tmp/a.pdf"), source: nil, at: t0.addingTimeInterval(2))
            .adding(files: files("/tmp/a.pdf", "/tmp/b.png"), source: nil, at: t0.addingTimeInterval(3))
        XCTAssertEqual(history.items.count, 3)
        XCTAssertEqual(history.items.first?.files?.count, 2)
        XCTAssertEqual(history.items[1].files?.count, 1)
    }

    func testCopyingNoFileAtAllChangesNothing() {
        XCTAssertTrue(ClipboardHistory.empty.adding(files: [], source: nil, at: t0).items.isEmpty)
    }

    /// Searching finds a file by its name and by the folder it came from.
    func testFilesAreFoundByPath() {
        let history = ClipboardHistory.empty
            .adding(files: files("/Users/x/Downloads/Report 2026.pdf"), source: "Finder", at: t0)
        XCTAssertEqual(history.matching("report").count, 1)
        XCTAssertEqual(history.matching("downloads pdf").count, 1)
        XCTAssertEqual(history.matching("invoice").count, 0)
    }

    func testFilesRoundTripThroughJSON() throws {
        let history = ClipboardHistory.empty
            .adding(files: files("/tmp/a.pdf", "/tmp/b.png"), source: "Finder", at: t0)
        let data = try JSONEncoder().encode(history)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardHistory.self, from: data), history)
    }

    // MARK: - What was read in a picture

    private func captioned(_ caption: String) -> ClipboardHistory {
        ClipboardHistory.empty
            .adding(image: image("a"), source: "Safari", at: t0)
            .captioning("a", with: caption)
    }

    func testCaptioningKeepsTheOriginalUntouched() {
        let original = ClipboardHistory.empty.adding(image: image("a"), source: nil, at: t0)
        _ = original.captioning("a", with: "Vimeo targeting")
        XCTAssertNil(original.items.first?.image?.caption)
    }

    func testCaptioningOnlyTheMatchingPicture() {
        let history = ClipboardHistory.empty
            .adding(image: image("a"), source: nil, at: t0)
            .adding(image: image("b"), source: nil, at: t0.addingTimeInterval(1))
            .captioning("a", with: "words")
        XCTAssertEqual(history.items.map { $0.image?.caption }, [nil, "words"])
    }

    /// Read once: a second reading cannot overwrite what the first found.
    func testAnAlreadyReadPictureKeepsItsWords() {
        let history = captioned("Vimeo targeting").captioning("a", with: "something else")
        XCTAssertEqual(history.items.first?.image?.caption, "Vimeo targeting")
    }

    /// Nothing to read is still read: empty, not nil, so the picture is not
    /// looked at again on every launch.
    func testNothingToReadIsRecordedAsEmpty() {
        let history = captioned("")
        XCTAssertEqual(history.items.first?.image?.caption, "")
        XCTAssertNil(history.items.first?.image?.captionLine)
    }

    func testTheRowShowsTheFirstLineThatHasWords() {
        XCTAssertEqual(captioned("\n  \n  Vimeo targeting  \nAudience\n").items.first?.image?.captionLine,
                       "Vimeo targeting")
    }

    func testAPictureIsFoundByWhatWasReadInIt() {
        let history = captioned("Vimeo targeting\nAudience")
        XCTAssertEqual(history.matching("targeting").count, 1)
        XCTAssertEqual(history.matching("audience vimeo").count, 1)
        XCTAssertTrue(history.matching("youtube").isEmpty)
    }

    /// Pictures stay findable as "image" and by the app they came from, read
    /// or not.
    func testAPictureIsStillFoundTheOldWays() {
        XCTAssertEqual(captioned("").matching("image safari").count, 1)
    }

    func testWordsSurviveSavingAndLoading() throws {
        let history = captioned("Vimeo targeting")
        let copy = try JSONDecoder().decode(ClipboardHistory.self,
                                            from: try JSONEncoder().encode(history))
        XCTAssertEqual(copy.items.first?.image?.caption, "Vimeo targeting")
    }
}

/// How a copied file reads in the list: its name, and the folder it sits in
/// with the home folder written the way the Finder does.
final class ClipFileTests: XCTestCase {

    func testNameAndFolder() {
        let file = ClipFile(path: "/Users/x/Downloads/Report.pdf")
        XCTAssertEqual(file.name, "Report.pdf")
        XCTAssertEqual(file.folder, "/Users/x/Downloads")
    }

    func testTheHomeFolderIsWrittenAsATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClipFile(path: home + "/Desktop/note.txt").folder, "~/Desktop")
        XCTAssertEqual(ClipFile(path: home + "/note.txt").folder, "~")
    }

    /// Another user's home is not this one's: the prefix must not match halfway
    /// through a folder name either.
    func testOtherPathsAreLeftAlone() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClipFile(path: home + "2/note.txt").folder, home + "2")
        XCTAssertEqual(ClipFile(path: "/Volumes/Disk/note.txt").folder, "/Volumes/Disk")
    }

    func testAMissingFileIsNotThere() {
        XCTAssertFalse(ClipFile(path: "/tmp/screenhere-no-such-file-\(UUID().uuidString)").exists)
        XCTAssertTrue(ClipFile(path: NSTemporaryDirectory()).exists)
    }
}
