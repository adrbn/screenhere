import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a visit brought back for a link.
struct LinkPreview: Codable, Equatable, Sendable {
    let title: String?
    let hasIcon: Bool
    let visited: Date

    /// Neither a title nor an icon: a dead link, or a site that refuses visits.
    var isEmpty: Bool { title == nil && !hasIcon }
}

/// Link previews on disk, next to the history: a small JSON file and an icon
/// per link, named by a digest of the address — readable by the owner only,
/// since the name of a page someone copied says what they copied.
struct LinkPreviewStore: Sendable {
    let directory: URL

    /// Longest side of a stored icon: sharp at 2x in a 20-point tile.
    static let iconPixels = 64
    /// Longest side of a picture decoded for an icon. A few kilobytes can
    /// claim a picture large enough to fill memory once decoded.
    static let maxIconSide = 2_048
    /// An empty visit is tried again after this long, not every time the list
    /// opens. A preview that worked is kept for as long as its link is.
    static let emptyRetry: TimeInterval = 24 * 3_600

    init(directory: URL = LinkPreviewStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        ClipboardHistoryStore.defaultDirectory.appendingPathComponent("LinkPreviews", isDirectory: true)
    }

    static func key(for link: CopiedLink) -> String {
        SHA256.hash(data: Data(link.visitURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func needsVisit(_ preview: LinkPreview?, now: Date) -> Bool {
        guard let preview else { return true }
        return now > nextVisit(after: preview)
    }

    /// Never for a preview that worked; a day later for an empty one.
    static func nextVisit(after preview: LinkPreview) -> Date {
        preview.isEmpty ? preview.visited.addingTimeInterval(emptyRetry) : .distantFuture
    }

    func preview(for key: String) -> LinkPreview? {
        guard let data = try? Data(contentsOf: fileURL(key, "json")) else { return nil }
        return try? JSONDecoder().decode(LinkPreview.self, from: data)
    }

    func icon(for key: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL(key, "png") as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func save(_ preview: LinkPreview, icon: Data?, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Also when it was already there: creating it sets nothing then.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let icon { try write(icon, to: fileURL(key, "png")) }
        try write(JSONEncoder().encode(preview), to: fileURL(key, "json"))
    }

    func remove(keys: Set<String>) {
        for key in keys {
            for ext in ["json", "png"] { try? FileManager.default.removeItem(at: fileURL(key, ext)) }
        }
    }

    /// Deletes previews of links the history no longer holds.
    func prune(keeping keys: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !keys.contains(file.deletingPathExtension().lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// An icon as a small PNG — the largest picture of a multi-size .ico. Nil
    /// for anything that is not a picture in a format icons come in, or that
    /// is larger than `maxSide`.
    static func smallIcon(from data: Data, maxSide: Int = maxIconSide) -> Data? {
        // A stranger's server picked these bytes; ImageIO reads many formats,
        // and only these few reach it.
        guard let type = iconType(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceTypeIdentifierHint: type] as CFDictionary),
              CGImageSourceGetType(source) as String? == type as String
        else { return nil }
        let sizes = (0..<CGImageSourceGetCount(source)).map { (index: $0, size: size(source, $0)) }
        let fitting = sizes.filter { (1...maxSide).contains($0.size.width) && (1...maxSide).contains($0.size.height) }
        guard let largest = fitting.max(by: { $0.size.width < $1.size.width })?.index else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: iconPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, largest, options as CFDictionary) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    /// From the picture's header, without decoding it.
    private static func size(_ source: CGImageSource, _ index: Int) -> (width: Int, height: Int) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    /// PNG, JPEG, GIF, WebP or ICO, told by their first bytes.
    private static func iconType(of data: Data) -> CFString? {
        let head = [UInt8](data.prefix(12))
        func starts(with bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && head[offset..<offset + bytes.count].elementsEqual(bytes)
        }
        if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return UTType.png.identifier as CFString }
        if starts(with: [0xFF, 0xD8, 0xFF]) { return UTType.jpeg.identifier as CFString }
        if starts(with: Array("GIF8".utf8)) { return UTType.gif.identifier as CFString }
        if starts(with: Array("RIFF".utf8)), starts(with: Array("WEBP".utf8), at: 8) { return UTType.webP.identifier as CFString }
        if starts(with: [0x00, 0x00, 0x01, 0x00]) { return UTType.ico.identifier as CFString }
        return nil
    }

    private func fileURL(_ key: String, _ ext: String) -> URL {
        directory.appendingPathComponent("\(key).\(ext)")
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        // Set after the atomic rename, which replaces the file and its mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
