import XCTest
@testable import ScreenHere

/// When the list visits links, and what it keeps: previews on disk, a visitor
/// standing in for the network.
@MainActor
final class LinkPreviewControllerTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var visitor: FakeVisitor!
    private var controller: LinkPreviewController!
    private var clock = Date()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHereLinkController-\(UUID().uuidString)")
        suite = "ScreenHereTests.LinkPreviews.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        visitor = FakeVisitor()
        controller = make()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// An update must never start visiting links on its own.
    func testOffUntilTurnedOn() async throws {
        controller.activate()
        XCTAssertFalse(controller.isEnabled)
        controller.want(try link("https://example.com/a"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(visitor.visited, [])
    }

    func testTheSettingIsRemembered() {
        controller.setEnabled(true)
        let next = make()
        next.activate()
        XCTAssertTrue(next.isEnabled)
    }

    func testAShownLinkIsVisitedOnceAndShown() async throws {
        controller.setEnabled(true)
        let a = try link("https://example.com/a")
        controller.want(a)
        controller.want(a)
        await eventually { self.controller.preview(for: a)?.title == "Title of /a" }
        controller.want(a)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(visitor.visited, ["https://example.com/a"])
    }

    func testAKeptPreviewNeedsNoVisit() async throws {
        let a = try link("https://example.com/a")
        try LinkPreviewStore(directory: directory)
            .save(LinkPreview(title: "Kept", hasIcon: false, visited: Date()), icon: nil, key: LinkPreviewStore.key(for: a))
        controller.setEnabled(true)
        controller.want(a)
        await eventually { self.controller.preview(for: a)?.title == "Kept" }
        XCTAssertEqual(visitor.visited, [])
    }

    func testSingleUseLinksAreNeverVisited() async throws {
        controller.setEnabled(true)
        controller.want(try link("https://example.com/password/reset?token=abc"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(visitor.visited, [])
    }

    func testAtMostThreeVisitsAtOnce() async throws {
        visitor.delay = 50_000_000
        controller.setEnabled(true)
        let all = try (1...7).map { try link("https://example.com/\($0)") }
        all.forEach(controller.want)
        await eventually { all.allSatisfy { self.controller.preview(for: $0) != nil } }
        XCTAssertEqual(visitor.mostAtOnce, LinkPreviewController.maxVisits)
    }

    /// Off means nothing kept — including what a visit under way brings back.
    func testTurningOffDeletesEverythingEvenAVisitUnderWay() async throws {
        let store = LinkPreviewStore(directory: directory)
        let kept = try link("https://example.com/kept")
        try store.save(LinkPreview(title: "Kept", hasIcon: false, visited: Date()), icon: nil,
                       key: LinkPreviewStore.key(for: kept))
        visitor.delay = 150_000_000
        controller.setEnabled(true)
        let a = try link("https://example.com/a")
        controller.want(a)
        await eventually { self.visitor.visited.count == 1 }
        controller.setEnabled(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(controller.preview(for: a))
        XCTAssertNil(store.preview(for: LinkPreviewStore.key(for: a)))
        XCTAssertNil(store.preview(for: LinkPreviewStore.key(for: kept)))
    }

    func testAForgottenLinkTakesItsPreviewWithIt() async throws {
        let store = LinkPreviewStore(directory: directory)
        controller.setEnabled(true)
        let a = try link("https://example.com/a")
        controller.want(a)
        await eventually { store.preview(for: LinkPreviewStore.key(for: a)) != nil }
        controller.forget([a], keeping: [])
        XCTAssertNil(controller.preview(for: a))
        await eventually { store.preview(for: LinkPreviewStore.key(for: a)) == nil }
    }

    /// A site down for a minute is tried again a day later, even with
    /// ScreenHere running all along — not every time the list opens.
    func testAnEmptyVisitIsTriedAgainADayLater() async throws {
        visitor.empty = true
        controller.setEnabled(true)
        let a = try link("https://example.com/a")
        controller.want(a)
        await eventually { self.visitor.visited.count == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.want(a)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(visitor.visited.count, 1)
        clock += LinkPreviewStore.emptyRetry + 60
        controller.want(a)
        await eventually { self.visitor.visited.count == 2 }
    }

    /// The same page copied twice, tracking parameters aside, shares one
    /// preview: a copy leaving the history leaves the other's in place.
    func testACopyStillInTheHistoryKeepsTheSharedPreview() async throws {
        let store = LinkPreviewStore(directory: directory)
        controller.setEnabled(true)
        let first = try link("https://example.com/a?utm_source=mail")
        let second = try link("https://example.com/a?utm_source=chat")
        controller.want(first)
        await eventually { store.preview(for: LinkPreviewStore.key(for: second)) != nil }
        controller.forget([first], keeping: [second])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(controller.preview(for: second))
        XCTAssertNotNil(store.preview(for: LinkPreviewStore.key(for: second)))
    }

    /// A visit parses a stranger's page and decodes its icon: never on the
    /// main thread, where it would hold up the app.
    func testVisitsRunAwayFromTheMainThread() async throws {
        controller.setEnabled(true)
        controller.want(try link("https://example.com/a"))
        await eventually { self.visitor.visited.count == 1 }
        XCTAssertEqual(visitor.onMainThread, [false])
    }

    // MARK: - Helpers

    private func make() -> LinkPreviewController {
        LinkPreviewController(store: LinkPreviewStore(directory: directory), visitor: visitor, defaults: defaults,
                              now: { [unowned self] in self.clock })
    }

    private func link(_ text: String) throws -> CopiedLink {
        try XCTUnwrap(CopiedLink(text: text))
    }

    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out", file: file, line: line)
    }
}

/// Gives every page a title from its path, after `delay` — or nothing at all,
/// as a dead link would.
private final class FakeVisitor: LinkVisiting, @unchecked Sendable {
    private let lock = NSLock()
    private var _visited: [String] = []
    private var running = 0
    private var _mostAtOnce = 0
    private var _onMainThread: [Bool] = []
    var delay: UInt64 = 0
    var empty = false

    var visited: [String] { lock.withLock { _visited } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    var onMainThread: [Bool] { lock.withLock { _onMainThread } }

    func visit(_ link: CopiedLink, now: Date) async -> (preview: LinkPreview, icon: Data?) {
        lock.withLock {
            _visited.append(link.visitURL.absoluteString)
            _onMainThread.append(pthread_main_np() != 0)
            running += 1
            _mostAtOnce = max(_mostAtOnce, running)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        lock.withLock { running -= 1 }
        let title = empty ? nil : "Title of \(link.url.path)"
        return (LinkPreview(title: title, hasIcon: false, visited: now), nil)
    }
}
