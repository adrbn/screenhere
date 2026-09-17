import AppKit
import XCTest
@testable import ScreenHere

/// Previews on disk, next to the history, and gone with it.
final class LinkPreviewStoreTests: XCTestCase {

    private var directory: URL!
    private var store: LinkPreviewStore!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHereLinks-\(UUID().uuidString)")
        store = LinkPreviewStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPreviewComesBack() throws {
        let key = try self.key("https://example.com/a")
        try store.save(LinkPreview(title: "A", hasIcon: true, visited: t0), icon: Self.png, key: key)
        XCTAssertEqual(store.preview(for: key), LinkPreview(title: "A", hasIcon: true, visited: t0))
        XCTAssertNotNil(store.icon(for: key))
    }

    func testFilesAreTheOwnersOnly() throws {
        let key = try self.key("https://example.com/a")
        try store.save(LinkPreview(title: "A", hasIcon: true, visited: t0), icon: Self.png, key: key)
        for name in ["\(key).json", "\(key).png"] {
            let path = directory.appendingPathComponent(name).path
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
    }

    /// Even when the folder was already there, readable by others.
    func testTheFolderIsTheOwnersOnly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try store.save(LinkPreview(title: "A", hasIcon: false, visited: t0), icon: nil, key: try key("https://example.com/a"))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    /// The same page with other tracking parameters is the same preview.
    func testTheKeyIsTheVisitedAddress() throws {
        XCTAssertEqual(try key("https://example.com/a?utm_source=x"), try key("https://example.com/a#top"))
        XCTAssertNotEqual(try key("https://example.com/a"), try key("https://example.com/b"))
    }

    func testAnUnvisitedLinkIsVisited() {
        XCTAssertTrue(LinkPreviewStore.needsVisit(nil, now: t0))
    }

    func testAPreviewIsKept() {
        let preview = LinkPreview(title: "A", hasIcon: false, visited: t0)
        XCTAssertFalse(LinkPreviewStore.needsVisit(preview, now: t0.addingTimeInterval(30 * 86_400)))
    }

    /// A dead or unreachable link is tried again a day later, not every time
    /// the list opens.
    func testAnEmptyVisitIsRetriedADayLater() {
        let empty = LinkPreview(title: nil, hasIcon: false, visited: t0)
        XCTAssertFalse(LinkPreviewStore.needsVisit(empty, now: t0.addingTimeInterval(3_600)))
        XCTAssertTrue(LinkPreviewStore.needsVisit(empty, now: t0.addingTimeInterval(86_401)))
    }

    func testRemovingAndPruning() throws {
        let a = try key("https://example.com/a")
        let b = try key("https://example.com/b")
        let c = try key("https://example.com/c")
        for k in [a, b, c] {
            try store.save(LinkPreview(title: k, hasIcon: true, visited: t0), icon: Self.png, key: k)
        }
        store.remove(keys: [a])
        XCTAssertNil(store.preview(for: a))
        XCTAssertNil(store.icon(for: a))

        store.prune(keeping: [b])
        XCTAssertNotNil(store.preview(for: b))
        XCTAssertNotNil(store.icon(for: b))
        XCTAssertNil(store.preview(for: c))
        XCTAssertNil(store.icon(for: c))
    }

    func testDeletingEverything() throws {
        let a = try key("https://example.com/a")
        try store.save(LinkPreview(title: "A", hasIcon: false, visited: t0), icon: nil, key: a)
        store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Any size of icon comes out small enough for a 20-point tile at 2x.
    func testIconsAreMadeSmall() throws {
        let icon = try XCTUnwrap(LinkPreviewStore.smallIcon(from: Self.picture(width: 512, height: 512)))
        let image = try XCTUnwrap(NSBitmapImageRep(data: icon))
        XCTAssertLessThanOrEqual(max(image.pixelsWide, image.pixelsHigh), LinkPreviewStore.iconPixels)
        XCTAssertNil(LinkPreviewStore.smallIcon(from: Data("<html>not found</html>".utf8)))
    }

    /// A stranger's server picks the bytes: only the formats icons come in
    /// reach the decoder.
    func testOnlyIconFormatsAreRead() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Self.png))
        XCTAssertNotNil(LinkPreviewStore.smallIcon(from: Self.png))
        XCTAssertNotNil(LinkPreviewStore.smallIcon(from: try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))))
        XCTAssertNotNil(LinkPreviewStore.smallIcon(from: try XCTUnwrap(rep.representation(using: .gif, properties: [:]))))
        XCTAssertNil(LinkPreviewStore.smallIcon(from: try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))))
        XCTAssertNil(LinkPreviewStore.smallIcon(from: try XCTUnwrap(rep.representation(using: .bmp, properties: [:]))))
    }

    /// A small file can claim a huge picture; it is not decoded to find out.
    func testAPictureTooLargeIsNotDecoded() throws {
        XCTAssertNil(LinkPreviewStore.smallIcon(from: Self.picture(width: 64, height: 16), maxSide: 32))
        XCTAssertNil(LinkPreviewStore.smallIcon(from: Self.picture(width: 16, height: 64), maxSide: 32))
        XCTAssertNotNil(LinkPreviewStore.smallIcon(from: Self.picture(width: 32, height: 32), maxSide: 32))
    }

    private func key(_ text: String) throws -> String {
        LinkPreviewStore.key(for: try XCTUnwrap(CopiedLink(text: text)))
    }

    private static let png = picture(width: 16, height: 16)

    private static func picture(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}
