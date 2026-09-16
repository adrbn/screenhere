import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Copied pictures on disk, next to the history: one file per picture, named
/// by its digest, and a small thumbnail for the list. Readable by the owner
/// only, like the history itself.
struct ClipboardImageStore: Sendable {
    let directory: URL

    /// Longest side of a list thumbnail, in pixels: sharp at 2x in a 72-point row.
    static let thumbnailPixels = 240
    /// A file this young may belong to a copy still on its way into the
    /// history, so a sweep leaves it alone.
    static let pruneGrace: TimeInterval = 60

    init(directory: URL = ClipboardImageStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        ClipboardHistoryStore.defaultDirectory.appendingPathComponent("ClipboardImages", isDirectory: true)
    }

    func fileURL(for image: ClipImage) -> URL {
        directory.appendingPathComponent("\(image.digest).\(image.format.fileExtension)")
    }

    func thumbnailURL(for image: ClipImage) -> URL {
        directory.appendingPathComponent("\(image.digest)-thumb.png")
    }

    /// Stores a copied picture and describes it. PNG and JPEG are kept as
    /// copied; anything else (TIFF above all) is re-encoded as PNG, losslessly.
    /// Nil for bytes ImageIO cannot read, or a picture over the size limit.
    func ingest(_ data: Data, type: String) throws -> ClipImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let format: ClipImage.Format = type == UTType.jpeg.identifier ? .jpeg : .png
        let keepsBytes = type == UTType.png.identifier || format == .jpeg
        guard let stored = keepsBytes ? data : Self.encode(source, as: .png) else { return nil }
        guard stored.count <= ClipboardHistory.maxImageBytes else { return nil }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let image = ClipImage(digest: digest, format: format, width: width, height: height,
                              byteCount: stored.count)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let file = fileURL(for: image)
        if fm.fileExists(atPath: file.path) {
            // Copied again: young again, so a sweep in progress spares it.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            try write(stored, to: file)
        }
        let thumbnail = thumbnailURL(for: image)
        if !fm.fileExists(atPath: thumbnail.path), let small = Self.thumbnail(of: source) {
            try? write(small, to: thumbnail)
        }
        return image
    }

    func data(for image: ClipImage) -> Data? {
        try? Data(contentsOf: fileURL(for: image))
    }

    func thumbnail(for image: ClipImage) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(thumbnailURL(for: image) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func remove(digests: Set<String>) {
        let fm = FileManager.default
        for digest in digests {
            for name in ["\(digest).png", "\(digest).jpg", "\(digest)-thumb.png"] {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Deletes files no history entry points at — left behind when the app
    /// stopped between writing a picture and saving the list.
    func prune(keeping digests: Set<String>, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let digest = name.hasSuffix("-thumb") ? String(name.dropLast("-thumb".count)) : name
            guard !digests.contains(digest) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > Self.pruneGrace {
                try? fm.removeItem(at: file)
            }
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        // Set after the atomic rename, which replaces the file and its mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func thumbnail(of source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, as: .png)
    }

    private static func encode(_ source: CGImageSource, as type: UTType) -> Data? {
        CGImageSourceCreateImageAtIndex(source, 0, nil).flatMap { encode($0, as: type) }
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
