import Foundation

/// A copied picture. The bytes live in `ClipboardImageStore`, in a file named
/// by the digest; the history only describes them.
struct ClipImage: Codable, Hashable, Sendable {
    enum Format: String, Codable, Sendable {
        case png, jpeg

        var fileExtension: String { self == .png ? "png" : "jpg" }
        var pasteboardType: String { self == .png ? "public.png" : "public.jpeg" }
    }

    /// SHA-256 of the copied bytes: names the file, and spots the same picture
    /// copied twice.
    let digest: String
    let format: Format
    let width: Int
    let height: Int
    /// Size on disk, which is what the image budget counts.
    let byteCount: Int
}

/// One thing the user copied.
struct ClipItem: Codable, Equatable, Identifiable {
    enum Content: Codable, Equatable {
        case text(String)
        case image(ClipImage)
    }

    let id: UUID
    let content: Content
    let date: Date
    /// The app that was in front when it was copied, for the list's subtitle.
    let source: String?

    init(id: UUID, content: Content, date: Date, source: String?) {
        self.id = id
        self.content = content
        self.date = date
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, date, source
        /// Before pictures, an item was its text.
        case legacyText = "text"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        if let content = try container.decodeIfPresent(Content.self, forKey: .content) {
            self.content = content
        } else {
            content = .text(try container.decode(String.self, forKey: .legacyText))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(source, forKey: .source)
    }

    var text: String? {
        if case .text(let text) = content { return text }
        return nil
    }

    var image: ClipImage? {
        if case .image(let image) = content { return image }
        return nil
    }
}

/// Everything copied while history is on, newest first. A value type: every
/// change returns a new history, so the model can publish it whole and the
/// store can write it without anyone mutating it underneath.
struct ClipboardHistory: Codable, Equatable {
    /// Enough to find "that thing I copied this morning" without the list
    /// turning into an archive.
    static let capacity = 200
    /// Characters. Bigger copies are skipped, never truncated: pasting back a
    /// silently shortened copy would lose data.
    static let maxLength = 100_000
    /// Disk space all pictures together may take. A Retina screenshot is a few
    /// megabytes, so this keeps a few dozen.
    static let imageBudget = 100 * 1024 * 1024
    /// One picture may not take a quarter of the budget on its own.
    static let maxImageBytes = 25 * 1024 * 1024

    private(set) var items: [ClipItem]

    static let empty = ClipboardHistory(items: [])

    func adding(_ text: String, source: String?, at date: Date, id: UUID = UUID()) -> ClipboardHistory {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxLength else { return self }
        let item = ClipItem(id: id, content: .text(text), date: date, source: source)
        return ClipboardHistory(items: [item] + items.filter { $0.text != text }).trimmed()
    }

    func adding(image: ClipImage, source: String?, at date: Date, id: UUID = UUID()) -> ClipboardHistory {
        guard image.byteCount <= Self.maxImageBytes else { return self }
        let item = ClipItem(id: id, content: .image(image), date: date, source: source)
        return ClipboardHistory(items: [item] + items.filter { $0.image?.digest != image.digest }).trimmed()
    }

    func removing(_ id: UUID) -> ClipboardHistory {
        filtering { $0.id != id }
    }

    func filtering(_ isIncluded: (ClipItem) -> Bool) -> ClipboardHistory {
        ClipboardHistory(items: items.filter(isIncluded))
    }

    /// The pictures this history still points at; any other file can go.
    var imageDigests: Set<String> {
        Set(items.compactMap(\.image?.digest))
    }

    /// Items containing every word of `query`, ignoring case and accents.
    func matching(_ query: String) -> [ClipItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = Self.fold(Self.searchableText(item))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Newest first, the capacity and the image budget both applied: past the
    /// budget the oldest pictures go — all of them, even one small enough to
    /// fit what is left — and the text around them stays.
    private func trimmed() -> ClipboardHistory {
        var kept: [ClipItem] = []
        var imageBytes = 0
        var overBudget = false
        for item in items where kept.count < Self.capacity {
            if let image = item.image {
                overBudget = overBudget || imageBytes + image.byteCount > Self.imageBudget
                guard !overBudget else { continue }
                imageBytes += image.byteCount
            }
            kept.append(item)
        }
        return ClipboardHistory(items: kept)
    }

    /// Pictures have no words of their own: they are found as "image" or by
    /// the app they came from.
    private static func searchableText(_ item: ClipItem) -> String {
        switch item.content {
        case .text(let text): return text
        case .image(let image): return "image \(image.width)×\(image.height) \(item.source ?? "")"
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension ClipboardHistory {
    private enum CodingKeys: String, CodingKey { case items }

    /// One unreadable entry — a torn write, a newer version's format — costs
    /// that entry, not the whole history, which the next save would overwrite.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .items)
        var items: [ClipItem] = []
        while !list.isAtEnd {
            if try list.decodeNil() { continue }
            if let item = try? list.decode(ClipItem.self) {
                items.append(item)
            } else {
                // A failed decode does not move past the entry.
                _ = try list.decode(Unreadable.self)
            }
        }
        self.init(items: items)
    }
}

private struct Unreadable: Decodable {
    init(from decoder: Decoder) {}
}
