import Foundation

protocol LinkVisiting: Sendable {
    func visit(_ link: CopiedLink, now: Date) async -> (preview: LinkPreview, icon: Data?)
}

/// Visits a link for its preview, the way a careful stranger would: no
/// cookies, no cache, no credentials, a few seconds and the top of the page at
/// most, nothing on a Low Data Mode network — and never a server on this
/// network, whether the link names it, redirects to it or resolves to it.
final class LinkVisitor: NSObject, LinkVisiting, URLSessionTaskDelegate, @unchecked Sendable {
    /// Titles live in the head, usually within its first few kilobytes — but
    /// YouTube's comes after 700 KB of inline script.
    static let maxPageBytes = 1_024 * 1_024
    static let maxIconBytes = 256 * 1_024
    /// Icons tried before giving up on one.
    static let maxIconTries = 3
    /// A name lookup gets as long as a request does. One can hang far longer
    /// than that, and cannot be cancelled.
    static let lookupTimeout: TimeInterval = 5

    typealias Resolver = @Sendable (String) async -> [String]

    private let resolve: Resolver
    private let lookupTimeout: TimeInterval
    // Set once in init; the session keeps its delegate until invalidated,
    // which a visitor living as long as the app never needs.
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = LinkVisitor.configuration(),
         lookupTimeout: TimeInterval = LinkVisitor.lookupTimeout,
         resolve: @escaping Resolver = { await LinkVisitor.addresses(of: $0) }) {
        self.resolve = resolve
        self.lookupTimeout = lookupTimeout
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": acceptLanguage,
        ]
        return configuration
    }

    /// Safari's, which sites answer with their real page, and ScreenHere's own
    /// name at the end so a site can tell what visited.
    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15 ScreenHere/\(version)"
    }

    /// Titles in the user's languages where a site has them.
    private static var acceptLanguage: String {
        Locale.preferredLanguages.prefix(3).enumerated()
            .map { $0.offset == 0 ? $0.element : "\($0.element);q=\(String(format: "%.1f", 1 - Double($0.offset) * 0.2))" }
            .joined(separator: ", ")
    }

    func visit(_ link: CopiedLink, now: Date = Date()) async -> (preview: LinkPreview, icon: Data?) {
        let url = link.visitURL
        guard link.mayVisit, await isPublic(url) else {
            return (LinkPreview(title: nil, hasIcon: false, visited: now), nil)
        }

        var head = PageHead(title: nil, icons: PageHeadParser.favicon(for: url).map { [$0] } ?? [])
        if let page = await fetch(url, accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
                                  limit: Self.maxPageBytes, page: true) {
            head = PageHeadParser.parse(PageHeadParser.text(from: page.data, contentType: page.contentType),
                                        url: page.url)
        }

        var icon: Data?
        for candidate in head.icons.prefix(Self.maxIconTries) {
            guard LinkSafety.mayVisitHost(candidate), await isPublic(candidate),
                  let fetched = await fetch(candidate, accept: "image/*", limit: Self.maxIconBytes, page: false),
                  let small = LinkPreviewStore.smallIcon(from: fetched.data)
            else { continue }
            icon = small
            break
        }
        return (LinkPreview(title: head.title, hasIcon: icon != nil, visited: now), icon)
    }

    // MARK: - Fetching

    struct Fetched {
        let data: Data
        let url: URL
        let contentType: String?
    }

    /// The start of a successful response, or nil. A page stops at the end of
    /// its head; anything that is not HTML comes back empty, since only its
    /// site's icon is of use.
    private func fetch(_ url: URL, accept: String, limit: Int, page: Bool) async -> Fetched? {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        return await withCheckedContinuation { continuation in
            task.delegate = PartialReader(limit: limit, page: page, fallbackURL: url, continuation: continuation)
            task.resume()
        }
    }

    static func isHTML(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased() else { return true }
        return type.contains("text/html") || type.contains("application/xhtml")
    }

    // MARK: - Where it goes

    /// Every address the host resolves to is public. A public name can point
    /// at a private address; a visit must not reach this network either way.
    private func isPublic(_ url: URL) async -> Bool {
        guard let host = url.host else { return false }
        let resolve = self.resolve
        let addresses = await Self.answer(within: lookupTimeout, otherwise: []) { await resolve(host) }
        return !addresses.isEmpty && !addresses.contains(where: LinkSafety.isPrivateAddress)
    }

    /// What `work` comes back with, or `fallback` if it has not within `seconds`.
    static func answer<T: Sendable>(within seconds: TimeInterval, otherwise fallback: T,
                                    _ work: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(returning: await work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                once.resume(returning: fallback)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, LinkSafety.mayVisit(url) else {
            completionHandler(nil)
            return
        }
        Task { completionHandler(await isPublic(url) ? request : nil) }
    }

    /// No site gets credentials from ScreenHere, whatever it asks.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.rejectProtectionSpace, nil)
        }
    }

    static func addresses(of host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: [])
                    return
                }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor {
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.append(String(cString: name))
                    }
                    cursor = entry.pointee.ai_next
                }
                freeaddrinfo(first)
                continuation.resume(returning: addresses)
            }
        }
    }
}

/// A continuation that the first of two answers resumes.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let waiting = lock.withLock {
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(returning: value)
    }
}

/// Reads a response as it arrives and hangs up once it has enough — rather
/// than downloading a whole page for the few kilobytes of its head.
private final class PartialReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let page: Bool
    private let fallbackURL: URL
    // Delegate calls for one task come one at a time, on the session's queue.
    private var continuation: CheckedContinuation<LinkVisitor.Fetched?, Never>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var head = HeadScanner()

    init(limit: Int, page: Bool, fallbackURL: URL, continuation: CheckedContinuation<LinkVisitor.Fetched?, Never>) {
        self.limit = limit
        self.page = page
        self.fallbackURL = fallbackURL
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            finish(nil)
            completionHandler(.cancel)
            return
        }
        self.response = http
        guard !page || LinkVisitor.isHTML(http.value(forHTTPHeaderField: "Content-Type")) else {
            finish(fetched())
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard continuation != nil else { return }
        data.append(chunk)
        if page { head.read(data) }
        if data.count >= limit || head.end != nil {
            data = data.prefix(limit)
            finish(fetched())
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && response != nil ? fetched() : nil)
    }

    private func fetched() -> LinkVisitor.Fetched {
        LinkVisitor.Fetched(data: data, url: response?.url ?? fallbackURL,
                            contentType: response?.value(forHTTPHeaderField: "Content-Type"))
    }

    private func finish(_ result: LinkVisitor.Fetched?) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
