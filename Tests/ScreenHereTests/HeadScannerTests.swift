import XCTest
@testable import ScreenHere

/// Where a page's head ends, and what of it is markup, as the page arrives.
final class HeadScannerTests: XCTestCase {

    func testTheHeadEndsAtItsCloseOrAtTheBody() {
        XCTAssertEqual(end(of: "<title>x</title></HEAD>"), 16)
        XCTAssertEqual(end(of: "<head><BODY class=a>"), 6)
        XCTAssertNil(end(of: "<head><title>x</title>"))
    }

    func testNotAtATagThatOnlyStartsTheSame() {
        XCTAssertNil(end(of: "<header></header><bodyguard>"))
    }

    func testNotInsideAScriptAStyleOrAComment() {
        XCTAssertNil(end(of: "<script>document.write('<body>')</script>"))
        XCTAssertNil(end(of: "<style>/* </head> */</style>"))
        XCTAssertNil(end(of: "<!-- <body> -->"))
        XCTAssertEqual(end(of: "<script>x</SCRIPT><body>"), 18)
    }

    /// Browsers read a title's text as text, even "<body>".
    func testNotInsideATitle() {
        XCTAssertNil(end(of: "<title>The <body> element</title>"))
    }

    func testAnEmptyCommentClosesItself() {
        XCTAssertEqual(end(of: "<!--><body>"), 5)
    }

    /// Pieces cut anywhere, even through "</script" or "<body", read the same.
    func testByteByByteReadsTheSame() {
        let page = "<head><script>'<body>'</script><!-- </head> --><title>A <b></title></head><body>"
        var scanner = HeadScanner()
        var bytes = Data()
        for byte in page.utf8 where scanner.end == nil {
            bytes.append(byte)
            scanner.read(bytes)
        }
        XCTAssertEqual(scanner.end, end(of: page))
        XCTAssertEqual(markup(of: page), "<head>\n</script>\n--><title>A <b></title>")
    }

    /// Their closing tags stay, which no pattern for a title or a link matches.
    func testTheMarkupLeavesOutScriptsStylesAndComments() {
        XCTAssertEqual(markup(of: "<meta a><script>x</script><style>y</style><!--z--><meta b>"),
                       "<meta a>\n</script>\n</style>\n--><meta b>")
    }

    // MARK: - Helpers

    private func end(of page: String) -> Int? {
        var scanner = HeadScanner()
        scanner.finish(Data(page.utf8))
        return scanner.end
    }

    private func markup(of page: String) -> String {
        var scanner = HeadScanner()
        let bytes = Data(page.utf8)
        scanner.finish(bytes)
        return scanner.markup.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "\n")
    }
}
