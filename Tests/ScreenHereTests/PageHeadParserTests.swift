import XCTest
@testable import ScreenHere

/// The title and icon of a page, read from the top of its HTML.
final class PageHeadParserTests: XCTestCase {

    private let page = URL(string: "https://example.com/blog/post")!

    func testTheTitle() {
        let head = PageHeadParser.parse("<html><head><title>Hello</title></head>", url: page)
        XCTAssertEqual(head.title, "Hello")
    }

    /// Open Graph titles leave out the site's suffix (" - YouTube").
    func testTheOpenGraphTitleWins() {
        let html = """
        <head><title>Video - YouTube</title>
        <meta property="og:title" content="Video"></head>
        """
        XCTAssertEqual(PageHeadParser.parse(html, url: page).title, "Video")
    }

    func testAttributesInAnyOrderAndQuoting() {
        XCTAssertEqual(PageHeadParser.parse("<META content='Quoted' property='og:title'>", url: page).title,
                       "Quoted")
        XCTAssertEqual(PageHeadParser.parse("<meta name=twitter:title content=Bare>", url: page).title, "Bare")
    }

    func testEntitiesAndWhitespaceAreCleanedUp() {
        let html = "<TITLE>\n  Tom &amp; Jerry &#8212; l&#x27;&eacute;t&eacute;&nbsp;!\n</TITLE>"
        XCTAssertEqual(PageHeadParser.parse(html, url: page).title, "Tom & Jerry — l'été !")
    }

    /// A title cannot turn itself around or hide characters to pass for
    /// another; emoji sequences keep their joiners.
    func testTitlesLoseDirectionAndInvisibleCharacters() {
        let html = "<title>Pay\u{202E}lanigiro\u{200B} \u{2066}bill\u{0007} 👨‍👩‍👧</title>"
        XCTAssertEqual(PageHeadParser.parse(html, url: page).title, "Paylanigiro bill 👨‍👩‍👧")
    }

    func testAnEmptyTitleIsNoTitle() {
        XCTAssertNil(PageHeadParser.parse("<title>   </title><meta property=\"og:title\" content=\"\">",
                                          url: page).title)
    }

    func testAVeryLongTitleIsShortened() throws {
        let long = String(repeating: "word ", count: 200)
        let title = try XCTUnwrap(PageHeadParser.parse("<title>\(long)</title>", url: page).title)
        XCTAssertLessThanOrEqual(title.count, PageHeadParser.maxTitleLength)
    }

    /// Only the head counts: a title inside an SVG in the body is not the page's.
    func testTheBodyIsNotRead() {
        let html = "<head></head><body><svg><title>Icon</title></svg></body>"
        XCTAssertNil(PageHeadParser.parse(html, url: page).title)
    }

    /// A script can carry markup in a string, and a comment an old title; the
    /// page's own title comes after both.
    func testScriptsStylesAndCommentsAreNotMarkup() {
        let html = """
        <head><script>var t = '<title>Not this</title><body>';</script>
        <style>/* <meta property="og:title" content="Nor this"> */</style>
        <!-- <title>Old</title> -->
        <title>This one</title></head>
        """
        XCTAssertEqual(PageHeadParser.parse(html, url: page).title, "This one")
    }

    func testIconsBestFirstThenTheFavicon() {
        let html = """
        <link rel="icon" href="/favicon-32.png">
        <link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
        """
        XCTAssertEqual(PageHeadParser.parse(html, url: page).icons.map(\.absoluteString), [
            "https://cdn.example.com/touch.png",
            "https://example.com/favicon-32.png",
            "https://example.com/favicon.ico",
        ])
    }

    func testRelativeIconsFollowTheBase() {
        let html = """
        <base href="https://static.example.com/assets/">
        <link rel="shortcut icon" href="icon.png">
        """
        XCTAssertEqual(PageHeadParser.parse(html, url: page).icons.first?.absoluteString,
                       "https://static.example.com/assets/icon.png")
    }

    /// ImageIO reads neither SVG nor inline data it would have to trust.
    func testUnreadableIconsAreSkipped() {
        let html = """
        <link rel="icon" href="/icon.svg">
        <link rel="mask-icon" href="/mask.png">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="javascript:alert(1)">
        """
        XCTAssertEqual(PageHeadParser.parse(html, url: page).icons.map(\.absoluteString),
                       ["https://example.com/favicon.ico"])
    }

    func testNoHeadStillHasTheFavicon() {
        let head = PageHeadParser.parse("", url: page)
        XCTAssertNil(head.title)
        XCTAssertEqual(head.icons.map(\.absoluteString), ["https://example.com/favicon.ico"])
    }

    // MARK: - Text

    func testTheDeclaredCharsetIsUsed() {
        let latin1 = "<title>été</title>".data(using: .isoLatin1)!
        XCTAssertEqual(PageHeadParser.text(from: latin1, contentType: "text/html; charset=ISO-8859-1"),
                       "<title>été</title>")
    }

    func testTheMetaCharsetIsUsed() {
        let latin1 = "<meta charset=\"windows-1252\"><title>été</title>".data(using: .windowsCP1252)!
        XCTAssertEqual(PageHeadParser.parse(PageHeadParser.text(from: latin1, contentType: "text/html"),
                                            url: page).title, "été")
    }

    func testUTF8IsTheDefault() {
        let utf8 = "<title>été</title>".data(using: .utf8)!
        XCTAssertEqual(PageHeadParser.text(from: utf8, contentType: nil), "<title>été</title>")
    }
}
