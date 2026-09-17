import Foundation

/// Splits the top of a page the way a browser reads it: markup on one side;
/// scripts, styles and comments on the other, whatever they hold. A script can
/// carry "<body>" or a "<title>" in a string, and neither ends the head nor
/// names the page. Reads as the page arrives, a piece at a time.
struct HeadScanner {
    /// Byte ranges of the markup read so far.
    private(set) var markup: [Range<Int>] = []
    /// Where "</head" or "<body" starts, once found in the markup.
    private(set) var end: Int?

    private enum Mode: Equatable {
        case markup
        /// Text up to `closing`; `isMarkup` for a title, whose text is kept.
        case text(closing: [UInt8], isMarkup: Bool)
    }

    private var mode = Mode.markup
    /// Bytes before this one are read.
    private var position = 0
    /// Where the markup being read began; nil inside a script, style or comment.
    private var markupStart: Int? = 0

    /// Reads on from where the last call stopped. `bytes` is all of the page
    /// so far, not just what came since.
    mutating func read(_ bytes: Data) {
        guard end == nil else { return }
        bytes.withUnsafeBytes { read($0, complete: false) }
    }

    /// The whole page, or all of it there will be: the markup runs to its end.
    mutating func finish(_ bytes: Data) {
        guard end == nil else { return }
        bytes.withUnsafeBytes { read($0, complete: true) }
        if end == nil, let start = markupStart, start < bytes.count {
            markup.append(start..<bytes.count)
        }
    }

    private mutating func read(_ bytes: UnsafeRawBufferPointer, complete: Bool) {
        while end == nil, position < bytes.count {
            switch mode {
            case .markup:
                guard let open = Self.find([UInt8(ascii: "<")], in: bytes, from: position) else {
                    position = bytes.count
                    return
                }
                position = open
                var unsure = false
                var found: Tag?
                for tag in Self.tags where found == nil {
                    switch tag.compare(bytes, at: open, complete: complete) {
                    case .yes: found = tag
                    case .unsure: unsure = true
                    case .no: break
                    }
                }
                guard let tag = found else {
                    // Too few bytes yet to tell what this tag is.
                    if unsure { return }
                    position = open + 1
                    continue
                }
                guard let next = tag.next else {
                    closeMarkup(at: open)
                    end = open
                    return
                }
                if case .text(_, false) = next { closeMarkup(at: open) }
                mode = next
                // Just past "<!", so that "<!-->" closes itself.
                position = open + 2

            case .text(let closing, let isMarkup):
                guard let close = Self.find(closing, in: bytes, from: position) else {
                    position = max(position, bytes.count - closing.count + 1)
                    return
                }
                if !isMarkup { markupStart = close }
                mode = .markup
                position = close + closing.count
            }
        }
    }

    private mutating func closeMarkup(at index: Int) {
        if let start = markupStart, start < index { markup.append(start..<index) }
        markupStart = nil
    }

    // MARK: - Tags

    private enum Match { case yes, no, unsure }

    private struct Tag {
        let opening: [UInt8]
        /// Whether a space, "/" or ">" must follow, so "<header>" is not "<head".
        let needsBoundary: Bool
        /// Nil where the head ends.
        let next: Mode?

        func compare(_ bytes: UnsafeRawBufferPointer, at index: Int, complete: Bool) -> Match {
            let available = bytes.count - index
            for offset in 0..<min(available, opening.count)
            where HeadScanner.lowercased(bytes[index + offset]) != opening[offset] {
                return .no
            }
            guard available >= opening.count else { return complete ? .no : .unsure }
            guard needsBoundary else { return .yes }
            guard available > opening.count else { return complete ? .yes : .unsure }
            return HeadScanner.boundaries.contains(bytes[index + opening.count]) ? .yes : .no
        }
    }

    private static let tags: [Tag] = [
        Tag(opening: Array("</head".utf8), needsBoundary: true, next: nil),
        Tag(opening: Array("<body".utf8), needsBoundary: true, next: nil),
        Tag(opening: Array("<!--".utf8), needsBoundary: false, next: .text(closing: Array("-->".utf8), isMarkup: false)),
        Tag(opening: Array("<script".utf8), needsBoundary: true,
            next: .text(closing: Array("</script".utf8), isMarkup: false)),
        Tag(opening: Array("<style".utf8), needsBoundary: true, next: .text(closing: Array("</style".utf8), isMarkup: false)),
        Tag(opening: Array("<title".utf8), needsBoundary: true, next: .text(closing: Array("</title".utf8), isMarkup: true)),
    ]

    private static let boundaries: Set<UInt8> = Set(" \t\n\r\u{0C}/>".utf8)

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// Where `token` next starts, in any case; nil if not in full yet.
    private static func find(_ token: [UInt8], in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        var from = start
        while from < bytes.count, let hit = memchr(base + from, Int32(token[0]), bytes.count - from) {
            let index = base.distance(to: UnsafeRawPointer(hit))
            guard index + token.count <= bytes.count else { return nil }
            if (1..<token.count).allSatisfy({ lowercased(bytes[index + $0]) == token[$0] }) { return index }
            from = index + 1
        }
        return nil
    }
}
