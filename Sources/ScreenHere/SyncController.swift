import AppKit
import CryptoKit
import Network

enum SyncPrefs {
    static let enabledKey = "SharedClipboardEnabled"
    static let deviceIDKey = "SharedClipboardDeviceID"
}

/// The other device, as kept between launches: who it is, and the key the two
/// made when they were introduced.
struct SyncPeer: Codable, Equatable {
    var id: String
    var name: String
    var key: Data
    /// Where it was last reached, for when its announcement does not get through.
    var host: String?
}

/// The peer on disk, next to the history and readable by its owner only.
struct SyncPeerStore {
    var directory: URL = ClipboardHistoryStore.defaultDirectory

    var fileURL: URL { directory.appendingPathComponent("SharedClipboard.json") }

    func load() -> SyncPeer? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SyncPeer.self, from: data)
    }

    func save(_ peer: SyncPeer) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(peer) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        // Set after the atomic rename, which replaces the file and its mode.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The shared clipboard (beta, off by default): what is copied on this Mac is
/// on the clipboard of the Mac or PC it was connected to, and the other way
/// round, while both are on the same network.
///
/// Nothing leaves that network: the two devices find each other with Bonjour,
/// talk to each other directly, and encrypt everything with a key made when
/// they were introduced. Text and pictures are shared; files are not, and
/// neither is anything a password manager marked as private.
@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController()

    /// A device announcing itself nearby.
    struct Found: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    /// The code both screens show while two devices are being introduced.
    struct Offer: Equatable {
        let name: String
        let code: String
        var confirmed: Bool
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var peer: SyncPeer?
    @Published private(set) var isConnected = false
    /// The panel is asking to connect a device: this one can be seen and asked.
    @Published private(set) var isPairing = false
    @Published private(set) var pending: Offer?
    @Published private(set) var nearby: [Found] = []

    private let defaults: UserDefaults
    private let store: SyncPeerStore
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connector: Timer?
    private var session: SyncSession?
    private var connecting = false
    private var waitingSince = Date()
    /// Answered by the buttons in the panel, or by whatever ends the question.
    private var decision: CheckedContinuation<Bool, Never>?
    private var pairingWire: SyncWire?
    /// Which question `decision` belongs to: an answer that comes in late
    /// must not settle the next one.
    private var round = 0
    /// What last arrived from the other device, and what last went to it:
    /// neither is sent again, so nothing can bounce between the two.
    private var lastRemote: String?
    private var lastSent: String?

    init(defaults: UserDefaults = .standard, store: SyncPeerStore = SyncPeerStore()) {
        self.defaults = defaults
        self.store = store
    }

    private var deviceID: String {
        if let id = defaults.string(forKey: SyncPrefs.deviceIDKey) { return id }
        let id = SyncProtocol.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        defaults.set(id, forKey: SyncPrefs.deviceIDKey)
        return id
    }

    private var deviceName: String { Host.current().localizedName ?? "Mac" }

    // MARK: - On and off

    /// Off unless the user turns it on: an update must never start sending
    /// what someone copies anywhere without them asking for it.
    func activate() {
        peer = store.load()
        isEnabled = defaults.bool(forKey: SyncPrefs.enabledKey)
        if isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: SyncPrefs.enabledKey)
        isEnabled = on
        if on { start() } else { stop() }
        ClipboardController.shared.watch()
        ClipboardController.shared.refreshAccess()
    }

    private func start() {
        waitingSince = Date()
        listen(on: NWEndpoint.Port(rawValue: SyncProtocol.preferredPort))
        browse()
        connector?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        connector = timer
    }

    private func stop() {
        connector?.invalidate()
        connector = nil
        endPairing()
        session?.close()
        session = nil
        isConnected = false
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        nearby = []
    }

    // MARK: - Finding each other

    /// Answers on a port of its own, and says so with Bonjour.
    private func listen(on port: NWEndpoint.Port?) {
        listener?.cancel()
        listener = nil
        guard let made = try? (port.map { try NWListener(using: .tcp, on: $0) } ?? NWListener(using: .tcp)) else { return }
        var record = NWTXTRecord()
        record["name"] = deviceName
        record["v"] = String(SyncProtocol.version)
        made.service = NWListener.Service(name: deviceID, type: SyncProtocol.serviceType, txtRecord: record)
        made.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(SyncWire(connection)) }
        }
        made.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                // The port is taken: any free one will do, Bonjour says which.
                guard let self, self.isEnabled, self.listener === made, port != nil else { return }
                self.listen(on: nil)
            }
        }
        made.start(queue: .main)
        listener = made
    }

    private func browse() {
        browser?.cancel()
        let made = NWBrowser(for: .bonjourWithTXTRecord(type: SyncProtocol.serviceType, domain: nil), using: .tcp)
        made.browseResultsChangedHandler = { [weak self] results, _ in
            let seen = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var shown = name
                if case .bonjour(let record) = result.metadata, let said = record["name"], !said.isEmpty { shown = said }
                return Found(id: name, name: shown, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.saw(seen) }
        }
        made.start(queue: .main)
        browser = made
    }

    private func saw(_ seen: [Found]) {
        guard isEnabled else { return }
        let own = deviceID
        let others = seen.filter { $0.id != own }.sorted { $0.name < $1.name }
        if others != nearby { nearby = others }
        if let peer, others.contains(where: { $0.id == peer.id }) { connect() }
    }

    // MARK: - Staying connected

    /// Tries to reach the other device, when there is one and no connection.
    /// Both sides may: the device whose id sorts first tries at once, the
    /// other gives it a few seconds — one of them may sit behind a firewall
    /// that lets nothing in.
    private func connect() {
        guard isEnabled, let peer, session == nil, !connecting, pending == nil else { return }
        let own = deviceID
        if own > peer.id, Date().timeIntervalSince(waitingSince) < 8 { return }

        var targets: [NWEndpoint] = []
        if let seen = nearby.first(where: { $0.id == peer.id }) { targets.append(seen.endpoint) }
        // Where it was last time, in case its announcement does not get through.
        if let host = peer.host, let port = NWEndpoint.Port(rawValue: SyncProtocol.preferredPort) {
            targets.append(.hostPort(host: NWEndpoint.Host(host), port: port))
        }
        guard !targets.isEmpty else { return }

        connecting = true
        Task { @MainActor in
            defer { self.connecting = false }
            for target in targets {
                let wire = SyncWire(NWConnection(to: target, using: .tcp))
                guard let made = await SyncSession.asClient(wire, ownID: own, peerID: peer.id, pairKey: peer.key) else { continue }
                if let host = wire.remoteHost, self.peer?.id == peer.id, self.peer?.host != host {
                    self.peer?.host = host
                    if let updated = self.peer { self.store.save(updated) }
                }
                self.adopt(made)
                return
            }
        }
    }

    /// Keeps `made` as the connection to the other device. When each side
    /// reached the other at the same moment there are two: both sides keep the
    /// one opened by the device whose id sorts first, so both keep the same.
    private func adopt(_ made: SyncSession) {
        guard isEnabled, made.peerID == peer?.id else { return made.close() }
        if let current = session {
            guard made.clientID <= current.clientID else { return made.close() }
            session = nil
            current.close()
        }
        session = made
        isConnected = true
        made.onReceive = { [weak self] kind, payload in self?.receive(kind, payload) }
        made.onClose = { [weak self, weak made] in
            guard let self, let made, self.session === made else { return }
            self.session = nil
            self.isConnected = false
            self.waitingSince = Date()
        }
        made.run()
    }

    // MARK: - Being reached

    private func serve(_ wire: SyncWire) {
        Task { @MainActor in
            guard isEnabled, (try? await wire.start(timeout: 10)) != nil,
                  let frame = try? await wire.receiveFrame(timeout: 10),
                  let first = SyncProtocol.decode(frame) else { return wire.cancel() }
            switch first.t {
            case "hello":
                guard let peer, first.id == peer.id,
                      let made = await SyncSession.asServer(wire, hello: first, ownID: deviceID, pairKey: peer.key)
                else { return wire.cancel() }
                adopt(made)
            case "pair1":
                await answerPairing(wire, asked: first)
            default:
                try? await wire.send(SyncProtocol.encode(.init(t: "no")))
                wire.cancel()
            }
        }
    }

    // MARK: - Sharing

    /// A text was copied on this Mac.
    func localCopy(text: String) {
        let bytes = Data(text.utf8)
        guard let session, !bytes.isEmpty, bytes.count <= SyncProtocol.maxText, isNews(bytes) else { return }
        session.send(.text, bytes)
    }

    /// A picture was copied on this Mac.
    func localCopy(png: Data) {
        guard let session, png.count <= ClipboardHistory.maxImageBytes, isNews(png) else { return }
        session.send(.image, png)
    }

    private func isNews(_ content: Data) -> Bool {
        let digest = Self.digest(content)
        guard digest != lastRemote, digest != lastSent else { return false }
        lastSent = digest
        return true
    }

    private func receive(_ kind: SyncProtocol.Kind, _ payload: Data) {
        let digest = Self.digest(payload)
        // What this Mac just sent, coming back: it has it already.
        guard isEnabled, digest != lastSent else { return }
        switch kind {
        case .text where payload.count <= SyncProtocol.maxText:
            lastRemote = digest
            ClipboardController.shared.write(String(decoding: payload, as: UTF8.self), source: peer?.name)
        case .image where payload.count <= ClipboardHistory.maxImageBytes:
            lastRemote = digest
            ClipboardController.shared.writeImage(payload, source: peer?.name)
        default:
            break
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Introducing two devices

    /// Whether the panel is on screen. Not published, and on purpose: the
    /// menu sizes its window while it is open and not while it is closed, so
    /// nothing the panel shows may change behind its back — rows that went
    /// away while it was closed left it floating between two empty bands.
    private var panelIsOpen = true
    private var pairingSince = Date()

    /// Connecting a device waits while the panel is closed: nothing is
    /// answered, and nothing it shows changes.
    func panelDidClose() {
        panelIsOpen = false
    }

    /// And goes on when it is back — unless it was left for so long that
    /// nobody is waiting on the other device any more.
    func panelDidOpen() {
        panelIsOpen = true
        if isPairing, pending == nil, Date().timeIntervalSince(pairingSince) > 600 { endPairing() }
    }

    /// While the panel is asking, this Mac answers a device that asks to be
    /// connected. The rest of the time it answers no one it does not know.
    func beginPairing() {
        guard isEnabled, !isPairing else { return }
        pairingSince = Date()
        isPairing = true
    }

    func endPairing() {
        guard isPairing || pending != nil else { return }
        isPairing = false
        decide(false)
        pairingWire?.cancel()
        pairingWire = nil
        pending = nil
    }

    /// Where this Mac can be reached, to type on the other device when it
    /// does not find this one by itself: "192.168.1.20", with the port after
    /// a colon when it is not the usual one.
    var ownAddress: String? {
        guard let address = Self.localAddresses().first else { return nil }
        guard let port = listener?.port?.rawValue, port != SyncProtocol.preferredPort else { return address }
        return "\(address):\(port)"
    }

    /// This Mac's IPv4 addresses on the networks it is on.
    static func localAddresses() -> [String] {
        var found: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // Self-assigned addresses lead nowhere.
            if !text.hasPrefix("169.254.") { found.append(text) }
        }
        return found
    }

    /// The user picked `device` in the panel: ask it.
    func pair(with device: Found) {
        guard isPairing, pending == nil, pairingWire == nil else { return }
        let wire = SyncWire(NWConnection(to: device.endpoint, using: .tcp))
        pairingWire = wire
        let (ownID, ownName) = (deviceID, deviceName)
        Task { @MainActor in
            defer {
                wire.cancel()
                if self.pairingWire === wire { self.pairingWire = nil }
            }
            guard (try? await wire.start(timeout: 5)) != nil else {
                if self.isPairing { Toast.show("Couldn't reach \(device.name) — try from there", systemImage: "exclamationmark.triangle") }
                return
            }
            let key = P256.KeyAgreement.PrivateKey()
            let (mine, nonce) = (SyncProtocol.publicBytes(key), SyncProtocol.randomBytes(32))
            let commit = SyncProtocol.commitment(publicKey: mine, nonce: nonce).base64EncodedString()
            guard (try? await wire.send(SyncProtocol.encode(.init(t: "pair1", v: SyncProtocol.version, id: ownID, name: ownName, commit: commit)))) != nil,
                  let frame = try? await wire.receiveFrame(timeout: 10), let answer = SyncProtocol.decode(frame),
                  answer.t == "pair2", let id = answer.id,
                  let theirs = Data(base64Encoded: answer.pub ?? ""), let theirNonce = Data(base64Encoded: answer.nonce ?? ""),
                  let shared = try? SyncProtocol.agree(key, with: theirs)
            else {
                if self.isPairing { Toast.show("\(device.name) is not asking to connect", systemImage: "exclamationmark.triangle") }
                return
            }
            guard (try? await wire.send(SyncProtocol.encode(.init(t: "pair3", pub: mine.base64EncodedString(), nonce: nonce.base64EncodedString())))) != nil
            else { return }
            let pairing = SyncProtocol.pairing(shared: shared, askingPublic: mine, answeringPublic: theirs,
                                               askingNonce: nonce, answeringNonce: theirNonce)
            await self.agree(wire, id: id, name: answer.name ?? device.name, key: pairing.key, code: pairing.code)
        }
    }

    private func answerPairing(_ wire: SyncWire, asked: SyncProtocol.Message) async {
        guard isPairing, panelIsOpen, pending == nil, pairingWire == nil,
              let id = asked.id, let commit = Data(base64Encoded: asked.commit ?? "") else {
            try? await wire.send(SyncProtocol.encode(.init(t: "no")))
            return wire.cancel()
        }
        pairingWire = wire
        defer {
            wire.cancel()
            if pairingWire === wire { pairingWire = nil }
        }
        let key = P256.KeyAgreement.PrivateKey()
        let (mine, nonce) = (SyncProtocol.publicBytes(key), SyncProtocol.randomBytes(32))
        guard (try? await wire.send(SyncProtocol.encode(.init(t: "pair2", v: SyncProtocol.version, id: deviceID, name: deviceName,
                                                             pub: mine.base64EncodedString(), nonce: nonce.base64EncodedString())))) != nil,
              let frame = try? await wire.receiveFrame(timeout: 10), let shown = SyncProtocol.decode(frame), shown.t == "pair3",
              let theirs = Data(base64Encoded: shown.pub ?? ""), let theirNonce = Data(base64Encoded: shown.nonce ?? ""),
              // The key it shows now must be the one it promised before seeing ours.
              SyncProtocol.commitment(publicKey: theirs, nonce: theirNonce) == commit,
              let shared = try? SyncProtocol.agree(key, with: theirs)
        else { return }
        let pairing = SyncProtocol.pairing(shared: shared, askingPublic: theirs, answeringPublic: mine,
                                           askingNonce: theirNonce, answeringNonce: nonce)
        await agree(wire, id: id, name: asked.name ?? "Device", key: pairing.key, code: pairing.code)
    }

    /// Both screens now show the same code — or someone is in the middle, and
    /// they do not. Each side says what its user decided; the devices are
    /// connected only when both said yes.
    private func agree(_ wire: SyncWire, id: String, name: String, key: Data, code: String) async {
        pending = Offer(name: name, code: code, confirmed: false)
        round += 1
        let asked = round
        let theirs = Task { () -> Bool in
            guard let frame = try? await wire.receiveFrame(timeout: 90), let answer = SyncProtocol.decode(frame) else { return false }
            return answer.ok == true
        }
        // Their no — or their silence — ends the question here too.
        Task { @MainActor in
            if await theirs.value == false, self.round == asked { self.decide(false) }
        }
        let mine = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.decision = continuation
        }
        try? await wire.send(SyncProtocol.encode(.init(t: "pair4", ok: mine)))
        let both = mine ? await theirs.value : false
        theirs.cancel()
        pending = nil
        if both {
            session?.close()
            session = nil
            isConnected = false
            let made = SyncPeer(id: id, name: name, key: key, host: wire.remoteHost)
            peer = made
            store.save(made)
            isPairing = false
            waitingSince = Date().addingTimeInterval(-30)
            Toast.show("Connected to \(name)", systemImage: "link")
            // Once this connection has had the time to close.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.connect() }
            }
        } else if mine {
            Toast.show("\(name) did not connect", systemImage: "exclamationmark.triangle")
        }
    }

    private func decide(_ yes: Bool) {
        decision?.resume(returning: yes)
        decision = nil
    }

    /// The user says the code is the same on both screens.
    func confirm() {
        guard pending?.confirmed == false, decision != nil else { return }
        pending?.confirmed = true
        decide(true)
    }

    func decline() {
        decide(false)
    }

    /// Forgets the other device and its key. It would have to be introduced again.
    func forget() {
        peer = nil
        store.delete()
        session?.close()
        session = nil
        isConnected = false
    }
}

/// A connection, as frames: each its length, then itself.
final class SyncWire: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.screenhere.shared-clipboard")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// The address at the other end, once connected.
    var remoteHost: String? {
        guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%").first
        case .ipv6(let address): return "\(address)".components(separatedBy: "%").first
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Resumes a continuation once, whichever of several callbacks comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    /// Waits until the connection is up. Throws when it cannot be made — a
    /// firewall, a device that left — rather than waiting for ever.
    func start(timeout: TimeInterval) async throws {
        let connection = self.connection
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: SyncProtocol.Failure.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.take() {
                    connection.cancel()
                    continuation.resume(throwing: SyncProtocol.Failure.closed)
                }
            }
        }
    }

    func send(_ body: Data) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: SyncProtocol.header(for: body.count) + body, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Queued behind what was sent before it, in the order it was asked.
    func sendNow(_ body: Data, onFailure: @escaping @Sendable () -> Void) {
        connection.send(content: SyncProtocol.header(for: body.count) + body, completion: .contentProcessed { error in
            if error != nil { onFailure() }
        })
    }

    private func receive(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let connection = self.connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? SyncProtocol.Failure.closed)
                }
            }
        }
    }

    /// The next frame. With a timeout, a connection that says nothing in that
    /// time is closed, which ends the wait.
    func receiveFrame(timeout: TimeInterval? = nil) async throws -> Data {
        let connection = self.connection
        let watchdog = timeout.map { limit in
            Task {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                connection.cancel()
            }
        }
        defer { watchdog?.cancel() }
        guard let length = SyncProtocol.length(from: try await receive(exactly: 4)) else { throw SyncProtocol.Failure.badFrame }
        return try await receive(exactly: length)
    }

    func cancel() {
        connection.cancel()
    }
}

/// A connection to the other device, once each side has shown it holds the
/// key they share.
@MainActor
final class SyncSession {
    let peerID: String
    /// The id of the side that opened the connection.
    let clientID: String
    var onReceive: ((SyncProtocol.Kind, Data) -> Void)?
    var onClose: (() -> Void)?

    private let wire: SyncWire
    private let sending: SyncProtocol.Cipher
    private let receiving: SyncProtocol.Cipher
    private var heard = Date()
    private var keepAlive: Timer?
    private var closed = false

    private init(wire: SyncWire, peerID: String, clientID: String, sendKey: Data, receiveKey: Data) {
        self.wire = wire
        self.peerID = peerID
        self.clientID = clientID
        sending = SyncProtocol.Cipher(key: sendKey)
        receiving = SyncProtocol.Cipher(key: receiveKey)
    }

    static func asClient(_ wire: SyncWire, ownID: String, peerID: String, pairKey: Data) async -> SyncSession? {
        let key = P256.KeyAgreement.PrivateKey()
        let nonce = SyncProtocol.randomBytes(32)
        let hello = SyncProtocol.Message(t: "hello", v: SyncProtocol.version, id: ownID,
                                         pub: SyncProtocol.publicBytes(key).base64EncodedString(), nonce: nonce.base64EncodedString())
        guard (try? await wire.start(timeout: 4)) != nil,
              (try? await wire.send(SyncProtocol.encode(hello))) != nil,
              let frame = try? await wire.receiveFrame(timeout: 10), let answer = SyncProtocol.decode(frame),
              answer.t == "hello", answer.id == peerID,
              let theirs = Data(base64Encoded: answer.pub ?? ""), let theirNonce = Data(base64Encoded: answer.nonce ?? ""),
              let shared = try? SyncProtocol.agree(key, with: theirs)
        else {
            wire.cancel()
            return nil
        }
        let keys = SyncProtocol.sessionKeys(shared: shared, pairKey: pairKey, clientNonce: nonce, serverNonce: theirNonce)
        let made = SyncSession(wire: wire, peerID: peerID, clientID: ownID, sendKey: keys.clientToServer, receiveKey: keys.serverToClient)
        return await made.greet() ? made : nil
    }

    static func asServer(_ wire: SyncWire, hello: SyncProtocol.Message, ownID: String, pairKey: Data) async -> SyncSession? {
        guard let peerID = hello.id,
              let theirs = Data(base64Encoded: hello.pub ?? ""), let theirNonce = Data(base64Encoded: hello.nonce ?? "")
        else { return nil }
        let key = P256.KeyAgreement.PrivateKey()
        let nonce = SyncProtocol.randomBytes(32)
        let answer = SyncProtocol.Message(t: "hello", v: SyncProtocol.version, id: ownID,
                                          pub: SyncProtocol.publicBytes(key).base64EncodedString(), nonce: nonce.base64EncodedString())
        guard let shared = try? SyncProtocol.agree(key, with: theirs),
              (try? await wire.send(SyncProtocol.encode(answer))) != nil
        else { return nil }
        let keys = SyncProtocol.sessionKeys(shared: shared, pairKey: pairKey, clientNonce: theirNonce, serverNonce: nonce)
        let made = SyncSession(wire: wire, peerID: peerID, clientID: peerID, sendKey: keys.serverToClient, receiveKey: keys.clientToServer)
        return await made.greet() ? made : nil
    }

    /// Each side seals one frame and opens the other's: whoever does not hold
    /// the key cannot do either.
    private func greet() async -> Bool {
        guard let ready = try? sending.seal(.ready), (try? await wire.send(ready)) != nil,
              let frame = try? await wire.receiveFrame(timeout: 10),
              let opened = try? receiving.open(frame), opened.kind == .ready
        else {
            wire.cancel()
            return false
        }
        return true
    }

    func run() {
        let wire = self.wire
        Task { @MainActor [weak self] in
            while let frame = try? await wire.receiveFrame() {
                guard let self, !self.closed, let opened = try? self.receiving.open(frame) else { break }
                self.heard = Date()
                if let kind = opened.kind, kind == .text || kind == .image { self.onReceive?(kind, opened.payload) }
            }
            self?.close()
        }
        // A connection that went quiet is a laptop that closed its lid.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.heard) > 65 { self.close() } else { self.send(.ping, Data()) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }

    /// Sealed and handed over at once, so frames leave in the order they are
    /// numbered.
    func send(_ kind: SyncProtocol.Kind, _ payload: Data) {
        guard !closed, let frame = try? sending.seal(kind, payload) else { return }
        wire.sendNow(frame) { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        keepAlive?.invalidate()
        keepAlive = nil
        wire.cancel()
        onClose?()
    }
}
