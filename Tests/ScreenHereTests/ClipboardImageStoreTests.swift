import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScreenHere

final class ClipboardImageStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ClipboardImageStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHereImages-\(UUID().uuidString)")
        store = ClipboardImageStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A small picture encoded as `type`, drawn rather than loaded so the test
    /// needs no fixtures.
    private func picture(_ type: UTType, width: Int = 64, height: Int = 40, seed: CGFloat = 0.3) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: seed, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testAPNGIsKeptAsIs() throws {
        let png = picture(.png)
        let image = try XCTUnwrap(store.ingest(png, type: "public.png"))
        XCTAssertEqual(image.format, .png)
        XCTAssertEqual([image.width, image.height], [64, 40])
        XCTAssertEqual(store.data(for: image), png)
        XCTAssertEqual(image.byteCount, png.count)
    }

    /// TIFF is uncompressed and huge; it is stored as PNG, losslessly.
    func testATIFFIsStoredAsPNG() throws {
        let image = try XCTUnwrap(store.ingest(picture(.tiff), type: "public.tiff"))
        XCTAssertEqual(image.format, .png)
        let stored = try XCTUnwrap(store.data(for: image))
        XCTAssertEqual(stored.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Re-encoding a photo as PNG would multiply its size.
    func testAJPEGStaysJPEG() throws {
        let image = try XCTUnwrap(store.ingest(picture(.jpeg), type: "public.jpeg"))
        XCTAssertEqual(image.format, .jpeg)
    }

    func testTheSamePictureTwiceIsOneFile() throws {
        let png = picture(.png)
        let first = try XCTUnwrap(store.ingest(png, type: "public.png"))
        let second = try XCTUnwrap(store.ingest(png, type: "public.png"))
        XCTAssertEqual(first, second)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { !$0.contains("-thumb") }.count, 1)
    }

    func testSomethingThatIsNotAPictureIsRefused() throws {
        XCTAssertNil(try store.ingest(Data("not an image".utf8), type: "public.png"))
    }

    func testAThumbnailIsMadeForTheList() throws {
        let image = try XCTUnwrap(store.ingest(picture(.png, width: 1600, height: 1000), type: "public.png"))
        let thumb = try XCTUnwrap(store.thumbnail(for: image))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), ClipboardImageStore.thumbnailPixels)
    }

    /// Pictures of what the user copied: nobody else on the Mac reads them.
    func testFilesAreReadableByTheOwnerOnly() throws {
        let image = try XCTUnwrap(store.ingest(picture(.png), type: "public.png"))
        let file = try FileManager.default.attributesOfItem(atPath: store.fileURL(for: image).path)
        XCTAssertEqual(file[.posixPermissions] as? Int, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(dir[.posixPermissions] as? Int, 0o700)
    }

    func testRemovingDeletesThePictureAndItsThumbnail() throws {
        let image = try XCTUnwrap(store.ingest(picture(.png), type: "public.png"))
        store.remove(digests: [image.digest])
        XCTAssertNil(store.data(for: image))
        XCTAssertNil(store.thumbnail(for: image))
    }

    /// Files no history entry points at — left by a crash between saving the
    /// picture and saving the list — are swept, but not one just written.
    func testPruneSweepsOnlyOldUnreferencedFiles() throws {
        let kept = try XCTUnwrap(store.ingest(picture(.png, seed: 0.1), type: "public.png"))
        let orphan = try XCTUnwrap(store.ingest(picture(.png, seed: 0.2), type: "public.png"))
        let fresh = try XCTUnwrap(store.ingest(picture(.png, seed: 0.3), type: "public.png"))
        let old = Date().addingTimeInterval(-3600)
        for image in [kept, orphan] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: store.fileURL(for: image).path)
        }
        store.prune(keeping: [kept.digest], now: Date())
        XCTAssertNotNil(store.data(for: kept))
        XCTAssertNil(store.data(for: orphan))
        XCTAssertNotNil(store.data(for: fresh))
    }

    func testDeleteAllEmptiesTheFolder() throws {
        _ = try store.ingest(picture(.png), type: "public.png")
        store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

/// Putting a picture back: its own format at once, TIFF only when asked —
/// on a private pasteboard, never the user's clipboard.
final class PasteboardImageWriterTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenHereTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func png() -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    func testThePictureIsOfferedAsPNGAndTIFF() {
        let data = png()
        let provider = PasteboardImageWriter.write(data, format: .png, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        let tiff = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiff)
        XCTAssertEqual(tiff.flatMap(NSBitmapImageRep.init(data:))?.pixelsWide, 8)
        withExtendedLifetime(provider) {}
    }

    /// Apps paste through NSImage as often as through raw types.
    func testNSImageReadsIt() {
        let provider = PasteboardImageWriter.write(png(), format: .png, to: pasteboard)
        let image = NSImage(pasteboard: pasteboard)
        XCTAssertEqual(image?.representations.first?.pixelsWide, 8)
        withExtendedLifetime(provider) {}
    }
}
