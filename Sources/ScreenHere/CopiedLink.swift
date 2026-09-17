import Foundation

/// A copy that is a web link and nothing else — the text a browser's address
/// bar or "Copy Link" puts on the clipboard.
struct CopiedLink: Hashable, Sendable {
    let url: URL

    /// Longer than any address a browser copies; spares parsing a pasted essay.
    private static let maxBytes = 4_096

    init?(text: String) {
        guard text.utf8.count <= Self.maxBytes else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.prefix(8).lowercased()
        guard scheme.hasPrefix("https://") || scheme.hasPrefix("http://"),
              !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed) ?? Self.encoded(trimmed),
              let host = url.host, !host.isEmpty
        else { return nil }
        self.url = url
    }

    /// "github.com", for the row's subtitle.
    var host: String {
        let host = (url.host ?? "").lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "github.com/adrbn/screenhere", for a row with no title.
    var display: String {
        var text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        return text
    }

    /// Whether a preview may visit it at all.
    var mayVisit: Bool { LinkSafety.mayVisit(url) }

    /// The address a visit asks for.
    var visitURL: URL { LinkSafety.visitURL(url) }

    /// Accented paths as some pages hand them over, before URL accepted them.
    private static func encoded(_ text: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }
}

extension ClipboardHistory {
    /// The texts in it that are links, for their previews.
    var links: Set<CopiedLink> {
        Set(items.compactMap { $0.text.flatMap(CopiedLink.init(text:)) })
    }
}

/// Which links a preview may visit. A visit is a GET to the link itself, with
/// no cookies: harmless for a page, but a link that signs in, resets a
/// password or confirms an address can be spent by it, and a local address
/// is nobody's business outside this network. Anything that looks like either
/// is left alone — a missed preview costs nothing, a spent link does. And only
/// over TLS: without it, a name could point at a public server for the check
/// and at this network for the visit, and a server here could answer for it.
enum LinkSafety {
    static func mayVisit(_ url: URL) -> Bool {
        guard mayVisitHost(url), url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return false }
        // "login.example.com": the site's own name, the last two labels, says nothing.
        let subdomains = (url.host ?? "").lowercased().split(separator: ".").dropLast(2).map(String.init)
        guard !subdomains.contains(where: looksSingleUse) else { return false }
        let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard !segments.contains(where: { looksSingleUse($0) || looksRandom($0) }) else { return false }
        for item in components.queryItems ?? [] where !isTracking(item.name) {
            if looksSecret(item.name) { return false }
            let value = item.value ?? ""
            if looksRandom(value) || value.contains("://") { return false }
        }
        return true
    }

    /// Scheme, host and port only: what an icon on another server needs.
    static func mayVisitHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", var host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if let port = url.port, port != 443 { return false }
        guard host.contains("."), !isAddress(host) else { return false }
        return !localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Without the fragment, which never reaches the server, and without
    /// tracking parameters, which have no business going along.
    static func visitURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        if let items = components.queryItems {
            let kept = items.filter { !isTracking($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? url
    }

    /// Loopback, private, link-local, carrier-grade NAT (Tailscale) and
    /// unspecified addresses, in either family — including an IPv4 address
    /// carried inside an IPv6 one. Unreadable counts as private.
    static func isPrivateAddress(_ text: String) -> Bool {
        var address = text
        if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return isPrivate(v4: withUnsafeBytes(of: v4.s_addr) { Array($0) })
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return true }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if let v4 = embeddedV4(b) { return isPrivate(v4: v4) }
        return (b[0] & 0xfe) == 0xfc                                        // fc00::/7
            || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)                      // fe80::/10
            || b[0] == 0xff                                                 // multicast
            || b[0..<6].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0x00, 0x01]) // 64:ff9b:1::/48, local NAT64
            || b[0..<4].elementsEqual([0x20, 0x01, 0x0d, 0xb8])             // 2001:db8::/32, documentation
    }

    /// The IPv4 address an IPv6 one carries: compatible (::a.b.c.d, which
    /// takes in :: and ::1), mapped (::ffff:a.b.c.d), NAT64 (64:ff9b::a.b.c.d)
    /// or 6to4 (2002:aabb:ccdd::).
    private static func embeddedV4(_ b: [UInt8]) -> [UInt8]? {
        if b[0..<10].allSatisfy({ $0 == 0 }), (b[10] == 0 && b[11] == 0) || (b[10] == 0xff && b[11] == 0xff) {
            return Array(b[12..<16])
        }
        if b[0..<12].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) { return Array(b[12..<16]) }
        if b[0] == 0x20, b[1] == 0x02 { return Array(b[2..<6]) }
        return nil
    }

    private static func isPrivate(v4 b: [UInt8]) -> Bool {
        b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224
            || (b[0] == 100 && (b[1] & 0xc0) == 64)
            || (b[0] == 169 && b[1] == 254)
            || (b[0] == 172 && (b[1] & 0xf0) == 16)
            || (b[0] == 192 && b[1] == 168)
    }

    private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static let localSuffixes: Set<String> = [
        "localhost", "local", "lan", "home", "home.arpa", "internal", "intranet", "corp",
        "test", "invalid", "ts.net",
    ]

    /// Words in a path that sign in, confirm or spend something.
    private static let singleUseWords: Set<String> = [
        "reset", "verify", "verification", "confirm", "confirmation", "magic", "login", "signin",
        "logout", "signout", "auth", "oauth", "oauth2", "sso", "saml", "callback", "invite",
        "invitation", "invitations", "unsubscribe", "activate", "activation", "token", "tokens", "otp",
        "onetime", "password", "passwords", "passwd", "recover", "recovery", "approve", "accept",
        "validate", "track", "tracking", "click", "clicks", "redirect", "redir",
    ]

    /// Query names that carry a secret. Matched as whole words…
    private static let secretWords: Set<String> = [
        "token", "code", "key", "secret", "sig", "signature", "auth", "otp", "password", "passwd",
        "pwd", "pass", "session", "sid", "ticket", "nonce", "state", "jwt", "hash", "credential",
        "credentials", "magic", "reset", "invite", "apikey", "accesskey",
    ]
    /// …and these anywhere in the name.
    private static let secretFragments = ["token", "secret", "passw", "signature", "session", "apikey", "credential"]

    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "mc_cid", "mc_eid", "igshid", "igsh", "si", "_ga", "_gl", "li_fat_id", "mkt_tok",
    ]

    private static func isTracking(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_") || trackingNames.contains(name)
    }

    private static func looksSecret(_ name: String) -> Bool {
        let name = name.lowercased()
        return secretFragments.contains { name.contains($0) } || matchesWord(in: name, of: secretWords)
    }

    private static func looksSingleUse(_ segment: String) -> Bool {
        matchesWord(in: (segment.removingPercentEncoding ?? segment).lowercased(), of: singleUseWords)
    }

    /// A word, or two neighbours written as one ("sign-in", "one-time").
    private static func matchesWord(in text: String, of words: Set<String>) -> Bool {
        let parts = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if parts.contains(where: words.contains) { return true }
        return zip(parts, parts.dropFirst()).contains { words.contains($0 + $1) }
    }

    /// A token rather than a word: a long run mixing letters and digits, or
    /// capitals and small letters in about equal measure, as identifiers,
    /// signatures and capability links are made — or a UUID. Readable slugs
    /// ("how-to-build-a-menu-bar-app") are short words, and camel case
    /// ("LinkPreviewController") has few capitals.
    private static func looksRandom(_ text: String) -> Bool {
        let text = text.removingPercentEncoding ?? text
        if text.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
                      options: .regularExpression) != nil { return true }
        let pieces = text.split(whereSeparator: { "-_.~+/=,:;".contains($0) || $0.isWhitespace })
        return pieces.contains { piece in
            guard piece.count >= 16 else { return false }
            let digits = piece.filter(\.isNumber).count
            let letters = piece.filter(\.isLetter).count
            let capitals = piece.filter(\.isUppercase).count
            let small = piece.filter(\.isLowercase).count
            return (digits >= 2 && letters >= 2) || (capitals * 4 >= piece.count && small * 4 >= piece.count)
        }
    }
}
