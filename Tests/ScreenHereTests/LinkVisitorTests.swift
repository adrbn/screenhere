import AppKit
import XCTest
@testable import ScreenHere

/// A visit, against pages served from memory: what it brings back, and where
/// it refuses to go.
final class LinkVisitorTests: XCTestCase {

    private static let publicAddress = "93.184.215.14"

    override func setUp() {
        StubServer.reset()
    }

    func testAPageGivesItsTitleAndIcon() async throws {
        StubServer.routes = [
            "https://example.com/post": .page("<head><title>A post</title><link rel=icon href=/i.png></head>"),
            "https://example.com/i.png": .data(Self.png, type: "image/png"),
        ]
        let (preview, icon) = await visitor().visit(try link("https://example.com/post"))
        XCTAssertEqual(preview.title, "A post")
        XCTAssertTrue(preview.hasIcon)
        XCTAssertNotNil(icon)
    }

    /// The tracking parameters and the fragment stay behind.
    func testTheVisitAsksForTheCleanAddress() async throws {
        StubServer.routes = ["https://example.com/post": .page("<title>A post</title>")]
        _ = await visitor().visit(try link("https://example.com/post?utm_source=mail#top"))
        XCTAssertEqual(StubServer.requested.first, "https://example.com/post")
    }

    func testNoCookiesAndNoCredentialsGoAlong() async throws {
        StubServer.routes = ["https://example.com/post": .page("<title>A post</title>")]
        _ = await visitor().visit(try link("https://example.com/post"))
        XCTAssertFalse(StubServer.cookieHeaders.isEmpty)
        XCTAssertTrue(StubServer.cookieHeaders.allSatisfy { $0 == nil })
    }

    func testASingleUseLinkIsNotVisited() async throws {
        let (preview, _) = await visitor().visit(try link("https://example.com/password/reset?token=abc"))
        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(StubServer.requested, [])
    }

    /// A public name can point at a private address.
    func testANameOnThisNetworkIsNotVisited() async throws {
        let (preview, _) = await visitor(resolvingTo: "192.168.1.10").visit(try link("https://router.example.com/"))
        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(StubServer.requested, [])
    }

    func testARedirectToThisNetworkIsNotFollowed() async throws {
        StubServer.routes = [
            "https://example.com/go": .redirect("http://192.168.1.10/admin"),
            "http://192.168.1.10/admin": .page("<title>Router</title>"),
        ]
        let (preview, _) = await visitor().visit(try link("https://example.com/go"))
        XCTAssertNil(preview.title)
        XCTAssertFalse(StubServer.requested.contains("http://192.168.1.10/admin"))
    }

    func testARedirectToAnUnencryptedPageIsNotFollowed() async throws {
        StubServer.routes = [
            "https://example.com/go": .redirect("http://example.com/page"),
            "http://example.com/page": .page("<title>Plain</title>"),
        ]
        let (preview, _) = await visitor().visit(try link("https://example.com/go"))
        XCTAssertNil(preview.title)
        XCTAssertFalse(StubServer.requested.contains("http://example.com/page"))
    }

    func testARedirectToAnOrdinaryPageIsFollowed() async throws {
        StubServer.routes = [
            "https://example.com/old": .redirect("https://example.com/new"),
            "https://example.com/new": .page("<title>Moved</title>"),
        ]
        let (preview, _) = await visitor().visit(try link("https://example.com/old"))
        XCTAssertEqual(preview.title, "Moved")
    }

    /// A title past the reading limit is not worth downloading a page for.
    func testReadingStopsAtTheLimit() async throws {
        let filler = String(repeating: "<meta name=x content=y>", count: LinkVisitor.maxPageBytes / 20)
        StubServer.routes = ["https://example.com/huge": .page("<head>\(filler)<title>Too far</title></head>")]
        let (preview, _) = await visitor().visit(try link("https://example.com/huge"))
        XCTAssertNil(preview.title)
    }

    /// A PDF has no title to read, but its site still has an icon.
    func testAFileThatIsNotAPageKeepsTheSiteIcon() async throws {
        StubServer.routes = [
            "https://example.com/paper.pdf": .data(Data("%PDF-1.7".utf8), type: "application/pdf"),
            "https://example.com/favicon.ico": .data(Self.png, type: "image/x-icon"),
        ]
        let (preview, icon) = await visitor().visit(try link("https://example.com/paper.pdf"))
        XCTAssertNil(preview.title)
        XCTAssertNotNil(icon)
    }

    func testAMissingPageIsEmpty() async throws {
        StubServer.routes = ["https://example.com/gone": .status(404)]
        let (preview, icon) = await visitor().visit(try link("https://example.com/gone"))
        XCTAssertNil(preview.title)
        XCTAssertNil(icon)
        XCTAssertTrue(preview.isEmpty)
    }

    /// A name that never resolves is given up on, rather than holding one of
    /// the few visits under way for good.
    func testAStuckLookupIsGivenUp() async throws {
        StubServer.routes = ["https://example.com/post": .page("<title>A post</title>")]
        let configuration = LinkVisitor.configuration()
        configuration.protocolClasses = [StubServer.self]
        let stuck = LinkVisitor(configuration: configuration, lookupTimeout: 0.1) { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return ["93.184.215.14"]
        }
        let started = Date()
        let (preview, _) = await stuck.visit(try link("https://example.com/post"))
        XCTAssertTrue(preview.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(StubServer.requested, [])
    }

    /// Reading stops at the head's end, not at "<body" in a script before it.
    func testAScriptHoldingMarkupDoesNotCutThePageShort() async throws {
        let script = "<script>var a = '<body>';" + String(repeating: " ", count: 100_000) + "</script>"
        StubServer.routes = ["https://example.com/app": .page("<head>\(script)<title>The app</title></head>")]
        let (preview, _) = await visitor().visit(try link("https://example.com/app"))
        XCTAssertEqual(preview.title, "The app")
    }

    // MARK: - Helpers

    private func visitor(resolvingTo address: String = publicAddress) -> LinkVisitor {
        let configuration = LinkVisitor.configuration()
        configuration.protocolClasses = [StubServer.self]
        return LinkVisitor(configuration: configuration, resolve: { _ in [address] })
    }

    private func link(_ text: String) throws -> CopiedLink {
        try XCTUnwrap(CopiedLink(text: text))
    }

    private static let png: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()
}

/// Serves pages from memory in place of the network.
private final class StubServer: URLProtocol {
    enum Route {
        case page(String)
        case data(Data, type: String)
        case redirect(String)
        case status(Int)
    }

    private static let lock = NSLock()
    private static var _routes: [String: Route] = [:]
    private static var _requested: [String] = []
    private static var _cookies: [String?] = []

    static var routes: [String: Route] {
        get { lock.withLock { _routes } }
        set { lock.withLock { _routes = newValue } }
    }
    static var requested: [String] { lock.withLock { _requested } }
    static var cookieHeaders: [String?] { lock.withLock { _cookies } }

    static func reset() {
        lock.withLock {
            _routes = [:]
            _requested = []
            _cookies = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock {
            Self._requested.append(url.absoluteString)
            Self._cookies.append(request.value(forHTTPHeaderField: "Cookie"))
        }
        switch Self.routes[url.absoluteString] ?? .status(404) {
        case .page(let html):
            respond(url, status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
        case .data(let data, let type):
            respond(url, status: 200, headers: ["Content-Type": type], body: data)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!),
                                redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let status):
            respond(url, status: status, headers: [:], body: Data())
        }
    }

    override func stopLoading() {}

    private func respond(_ url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
