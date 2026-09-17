import Foundation

/// What a link preview shows of a page.
struct PageHead: Equatable {
    let title: String?
    /// Best first, the site's /favicon.ico last.
    let icons: [URL]
}

/// Reads a page's title and icons from the top of its HTML. Patterns, not a
/// parser: the head is a handful of flat tags, and a preview that misses an
/// odd page costs nothing.
enum PageHeadParser {
    static let maxTitleLength = 200

    static func parse(_ html: String, url: URL) -> PageHead {
        let head = headMarkup(html)
        var base = url
        var metaTitles: [String: String] = [:]
        var icons: [(rank: Int, size: Int, order: Int, url: URL)] = []

        for (order, tag) in tags(in: head).enumerated() {
            let attributes = self.attributes(of: tag.body)
            switch tag.name {
            case "base":
                if let href = attributes["href"], let resolved = URL(string: href, relativeTo: url)?.absoluteURL {
                    base = resolved
                }
            case "meta":
                if let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                   key == "og:title" || key == "twitter:title",
                   metaTitles[key] == nil, let content = attributes["content"] {
                    metaTitles[key] = content
                }
            default:
                guard let rank = iconRank(attributes["rel"]), let href = attributes["href"],
                      attributes["type"]?.lowercased().contains("svg") != true
                else { continue }
                guard let icon = URL(string: href, relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(icon.scheme?.lowercased() ?? ""),
                      icon.pathExtension.lowercased() != "svg"
                else { continue }
                icons.append((rank, largestSize(attributes["sizes"]), order, icon))
            }
        }

        let candidates = [metaTitles["og:title"], metaTitles["twitter:title"], titleElement(in: head)]
        let title = candidates.lazy.compactMap { $0.flatMap(clean) }.first

        var ordered = icons
            .sorted { ($0.rank, -$0.size, $0.order) < ($1.rank, -$1.size, $1.order) }
            .map(\.url)
        if let favicon = favicon(for: url), !ordered.contains(favicon) { ordered.append(favicon) }
        return PageHead(title: title, icons: ordered)
    }

    static func favicon(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// The bytes as text: the charset the server declared, else the one the
    /// page declares, else UTF-8, with anything unreadable replaced.
    static func text(from data: Data, contentType: String?) -> String {
        let prefix = String(decoding: data.prefix(2_048), as: UTF8.self)
        for declared in [contentType.flatMap(charset(in:)), charset(in: prefix)] {
            if let declared, let encoding = encoding(named: declared), let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Pieces

    /// The head's markup: up to where the body starts, since an SVG's <title>
    /// there is not the page's, and without scripts, styles or comments.
    private static func headMarkup(_ html: String) -> String {
        let bytes = Data(html.utf8)
        var scanner = HeadScanner()
        scanner.finish(bytes)
        // Pieces start and end at a "<" or a ">", never inside a character.
        return scanner.markup.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "\n")
    }

    private static let tagPattern = cached(#"<(meta|link|base)\b([^>]*)>"#)
    private static let titlePattern = cached(#"<title\b[^>]*>(.*?)</title\s*>"#)
    private static let attributePattern = cached(#"([^\s=/>"']+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let charsetPattern = cached(#"charset\s*=\s*["']?([A-Za-z0-9_\-:.]+)"#)

    private static func cached(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func tags(in string: String) -> [(name: String, body: String)] {
        let range = NSRange(string.startIndex..., in: string)
        return tagPattern.matches(in: string, range: range).compactMap { match in
            guard let name = Range(match.range(at: 1), in: string),
                  let body = Range(match.range(at: 2), in: string) else { return nil }
            return (string[name].lowercased(), String(string[body]))
        }
    }

    private static func titleElement(in string: String) -> String? {
        guard let match = titlePattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }

    private static func attributes(of body: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let name = Range(match.range(at: 1), in: body) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: body) }.first
            let key = body[name].lowercased()
            if result[key] == nil { result[key] = value.map { decodeEntities(String(body[$0])) } ?? "" }
        }
        return result
    }

    /// 0 for Apple's touch icons (large and square), 1 for plain icons.
    private static func iconRank(_ rel: String?) -> Int? {
        let tokens = Set((rel ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        if tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed") { return 0 }
        return tokens.contains("icon") ? 1 : nil
    }

    private static func largestSize(_ sizes: String?) -> Int {
        (sizes ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            .max() ?? 0
    }

    /// Entities decoded, whitespace collapsed, and without the characters a
    /// title could use to turn itself around or hide part of itself.
    private static func clean(_ raw: String) -> String? {
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: decodeEntities(raw).unicodeScalars.filter(isVisible))
        let text = String(visible).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard text.count > maxTitleLength else { return text }
        return String(text.prefix(maxTitleLength - 1)) + "…"
    }

    /// Not a direction override, a zero-width character or a control one.
    /// Joiners stay: emoji sequences and some scripts are written with them.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format: return scalar.value == 0x200C || scalar.value == 0x200D
        case .control: return scalar.properties.isWhitespace
        default: return true
        }
    }

    private static func charset(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = charsetPattern.firstMatch(in: text, range: range),
              let name = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[name])
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: - Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}",
        "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•", "copy": "©",
        "reg": "®", "trade": "™", "euro": "€",
        "agrave": "à", "aacute": "á", "acirc": "â", "auml": "ä", "ccedil": "ç", "egrave": "è",
        "eacute": "é", "ecirc": "ê", "euml": "ë", "icirc": "î", "iuml": "ï", "ocirc": "ô",
        "ouml": "ö", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "oelig": "œ",
        "Agrave": "À", "Eacute": "É", "Egrave": "È", "Ecirc": "Ê", "Ccedil": "Ç",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";"), let decoded = entity(String(after[..<semi])) {
                result += decoded
                rest = after[after.index(after: semi)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first.map { "xX".contains($0) } == true
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[name]
    }
}
