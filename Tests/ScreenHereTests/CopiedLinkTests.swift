import XCTest
@testable import ScreenHere

/// Which copies are links, and which of those a preview may visit. A visit is a
/// GET to the link itself: one that signs in, resets a password or confirms an
/// email can be spent by it, so anything that looks like one stays unvisited.
final class CopiedLinkTests: XCTestCase {

    // MARK: - What is a link

    func testALinkAloneIsALink() throws {
        let link = try XCTUnwrap(CopiedLink(text: "https://github.com/adrbn/screenhere"))
        XCTAssertEqual(link.url.absoluteString, "https://github.com/adrbn/screenhere")
        XCTAssertEqual(link.host, "github.com")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertNotNil(CopiedLink(text: "  https://example.com/page\n"))
    }

    /// A sentence with a link in it is text: its row stays a text row.
    func testTextAroundALinkIsNotALink() {
        XCTAssertNil(CopiedLink(text: "see https://example.com/page"))
        XCTAssertNil(CopiedLink(text: "https://example.com/a https://example.com/b"))
    }

    func testOnlyWebLinksCount() {
        XCTAssertNil(CopiedLink(text: "ftp://example.com/file"))
        XCTAssertNil(CopiedLink(text: "mailto:someone@example.com"))
        XCTAssertNil(CopiedLink(text: "file:///Users/someone/notes.txt"))
        XCTAssertNil(CopiedLink(text: "example.com/page"))
        XCTAssertNil(CopiedLink(text: "https://"))
    }

    /// Browsers copy accented paths as typed on some pages.
    func testAccentedPathsAreLinks() throws {
        let link = try XCTUnwrap(CopiedLink(text: "https://fr.wikipedia.org/wiki/Été"))
        XCTAssertEqual(link.host, "fr.wikipedia.org")
    }

    func testWwwIsLeftOutOfTheHost() throws {
        XCTAssertEqual(try XCTUnwrap(CopiedLink(text: "https://www.apple.com/fr/")).host, "apple.com")
    }

    func testDisplayDropsTheSchemeAndTrailingSlash() throws {
        XCTAssertEqual(try XCTUnwrap(CopiedLink(text: "https://www.apple.com/fr/")).display, "apple.com/fr")
        XCTAssertEqual(try XCTUnwrap(CopiedLink(text: "http://example.com")).display, "example.com")
    }

    // MARK: - What is visited

    func testAnOrdinaryPageIsVisited() {
        XCTAssertTrue(visits("https://github.com/adrbn/screenhere"))
        XCTAssertTrue(visits("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"))
        XCTAssertTrue(visits("https://fr.wikipedia.org/wiki/Paris"))
        XCTAssertTrue(visits("https://example.com/authors/jane"))
        XCTAssertTrue(visits("https://example.com/blog/how-to-build-a-menu-bar-app-in-swift-2026"))
        XCTAssertTrue(visits("https://x.com/someone/status/1834567890123456789"))
        XCTAssertTrue(visits("https://www.google.com/search?q=swift+concurrency+2026"))
        XCTAssertTrue(visits("https://github.com/adrbn/screenhere/blob/main/Sources/ScreenHere/LinkPreviewController.swift"))
        XCTAssertTrue(visits("https://login.gov/"), "a site's own name is not a sign-in address")
    }

    /// Without TLS, a name could be made to point here between the check and
    /// the visit; with it, a server here cannot pass for the site.
    func testOnlyEncryptedLinksAreVisited() {
        XCTAssertFalse(visits("http://example.com/post"))
        XCTAssertTrue(visits("https://example.com:443/post"))
    }

    func testSignInHostsAreNotVisited() {
        XCTAssertFalse(visits("https://login.acme.com/l/8f3a2b1"))
        XCTAssertFalse(visits("https://auth.example.com/o/Qx7Fk2"))
        XCTAssertFalse(visits("https://click.mail.example.com/abc"))
    }

    func testLocalAndPrivateHostsAreNotVisited() {
        XCTAssertFalse(visits("http://localhost:3000/"))
        XCTAssertFalse(visits("http://printer.local/"))
        XCTAssertFalse(visits("http://asgard/"), "a name with no dot is a local one")
        XCTAssertFalse(visits("https://asgard.tail1234.ts.net/"))
        XCTAssertFalse(visits("http://192.168.1.10:8090/"))
        XCTAssertFalse(visits("http://100.99.174.79:8765/"))
        XCTAssertFalse(visits("https://8.8.8.8/"), "an address is never visited, public or not")
        XCTAssertFalse(visits("http://[::1]/"))
        XCTAssertFalse(visits("https://example.com:8443/"), "a port of its own is a development server")
    }

    func testCredentialsInTheLinkAreNotVisited() {
        XCTAssertFalse(visits("https://user:secret@example.com/"))
    }

    func testSecretsInTheQueryAreNotVisited() {
        XCTAssertFalse(visits("https://example.com/cb?token=abc"))
        XCTAssertFalse(visits("https://example.com/cb?access_token=abc"))
        XCTAssertFalse(visits("https://example.com/?code=123456"))
        XCTAssertFalse(visits("https://example.com/?api_key=abc"))
        XCTAssertFalse(visits("https://example.com/?apikey=abc"))
        XCTAssertFalse(visits("https://example.com/?sig=abc"))
        XCTAssertFalse(visits("https://example.com/?X-Amz-Signature=abc"))
    }

    func testLongRandomValuesAreNotVisited() {
        XCTAssertFalse(visits("https://example.com/open?id=Qm9vbGVhbjEyMzQ1Njc4OTBhYmNkZWZn"))
        XCTAssertFalse(visits("https://docs.google.com/document/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit"))
        XCTAssertFalse(visits("https://example.com/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.sig"))
        XCTAssertFalse(visits("https://example.com/share/123e4567-e89b-12d3-a456-426614174000"))
        XCTAssertFalse(visits("https://example.com/m/AbCdEfGhIjKlMnOpQrSt"), "mixed case, no digits")
        XCTAssertFalse(visits("https://example.com/go?to=https%3A%2F%2Felsewhere.com%2Fpage"),
                       "a redirector passes the visit on to somewhere else")
    }

    func testSingleUsePathsAreNotVisited() {
        XCTAssertFalse(visits("https://example.com/password/reset"))
        XCTAssertFalse(visits("https://example.com/reset-password"))
        XCTAssertFalse(visits("https://example.com/users/confirmation"))
        XCTAssertFalse(visits("https://example.com/email/verify"))
        XCTAssertFalse(visits("https://example.com/auth/callback"))
        XCTAssertFalse(visits("https://example.com/login"))
        XCTAssertFalse(visits("https://example.com/invite/abc"))
        XCTAssertFalse(visits("https://example.com/unsubscribe"))
        XCTAssertFalse(visits("https://example.com/magic-link"))
        XCTAssertFalse(visits("https://example.com/track/click"))
    }

    /// Tracking parameters say nothing about the page: they neither block a
    /// visit nor go along with it.
    func testTrackingParametersAreIgnoredAndLeftBehind() throws {
        let link = try XCTUnwrap(CopiedLink(text:
            "https://example.com/article?id=7&utm_source=newsletter&fbclid=IwAR2x9Qm9vbGVhbjEyMzQ1Njc4OTBhYmNk#comments"))
        XCTAssertTrue(link.mayVisit)
        XCTAssertEqual(link.visitURL.absoluteString, "https://example.com/article?id=7")
    }

    /// The fragment never reaches the server, so a token there spends nothing —
    /// and the visit leaves it behind anyway.
    func testTheFragmentIsLeftBehind() throws {
        let link = try XCTUnwrap(CopiedLink(text: "https://example.com/app#access_token=abc"))
        XCTAssertTrue(link.mayVisit)
        XCTAssertEqual(link.visitURL.absoluteString, "https://example.com/app")
    }

    // MARK: - Addresses

    func testPrivateAddresses() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.10",
                        "169.254.1.1", "100.64.0.1", "100.127.255.255", "0.0.0.0",
                        "::1", "fe80::1", "fd7a:115c:a1e0::1", "::ffff:192.168.1.1", "::",
                        "::192.168.1.1", "64:ff9b::c0a8:10a", "64:ff9b:1::1", "2002:c0a8:10a::1",
                        "2001:db8::1"] {
            XCTAssertTrue(LinkSafety.isPrivateAddress(address), address)
        }
    }

    func testPublicAddresses() {
        for address in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "140.82.121.4", "2606:4700::1111",
                        "64:ff9b::808:808", "2002:808:808::1"] {
            XCTAssertFalse(LinkSafety.isPrivateAddress(address), address)
        }
    }

    // MARK: - History

    func testTheHistoryKnowsItsLinks() throws {
        let history = ClipboardHistory.empty
            .adding("https://example.com/a", source: nil, at: Date())
            .adding("plain text", source: nil, at: Date())
            .adding("https://example.com/b", source: nil, at: Date())
        XCTAssertEqual(history.links, [try XCTUnwrap(CopiedLink(text: "https://example.com/a")),
                                       try XCTUnwrap(CopiedLink(text: "https://example.com/b"))])
    }

    private func visits(_ text: String) -> Bool {
        guard let link = CopiedLink(text: text) else {
            XCTFail("not a link: \(text)")
            return false
        }
        return link.mayVisit
    }
}
