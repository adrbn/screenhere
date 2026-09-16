import Foundation
import os

/// ScreenHere's side of the reader service — see `RecognitionPlan` for why
/// the accurate engine runs in a separate process that stays up.
@MainActor
final class TextReader {
    static let shared = TextReader(executable: Bundle.main.executableURL)

    /// Far beyond the ~110s the beta's slowest compile took, short of a hung
    /// service living forever.
    private static let loadLimit: TimeInterval = 480
    private static let readLimit: TimeInterval = 240

    private(set) var state: ReaderState = .stopped
    /// The engine the next service runs. One that works is kept for as long
    /// as ScreenHere runs.
    private var engine: ReaderEngine = .current
    private var failures = 0
    private var lastFailure: Date?
    private let executable: URL?
    private var service: Service?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private let log = Logger(subsystem: "com.screenhere.app", category: "text-reader")

    init(executable: URL?) {
        self.executable = executable
    }

    var plan: RecognitionPlan {
        RecognitionPlan.decide(reader: state, failures: failures, lastFailure: lastFailure, now: Date())
    }

    /// Launches the service, which loads the models in the background.
    func start() {
        guard state == .stopped, let executable else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [ReaderService.argument] + engine.arguments
        process.qualityOfService = .utility
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A service that died must fail the write, not kill ScreenHere.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // The main queue keeps the chunks, and the end, in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if data.isEmpty { self?.ended(process) } else { self?.received(data, from: process) }
                }
            }
        }
        do {
            try process.run()
        } catch {
            log.error("Could not launch the reader: \(error.localizedDescription, privacy: .public)")
            recordFailure()
            return
        }
        service = Service(process: process, input: input.fileHandleForWriting)
        state = .loading
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadLimit) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.service?.process === process, self.state == .loading else { return }
                self.log.error("The reader was still loading after \(Int(Self.loadLimit))s; stopping it.")
                process.terminate()
            }
        }
    }

    /// Stops the service — ⇧⌘7 turned off, or ScreenHere quitting.
    func stop() {
        guard let service else { return }
        self.service = nil
        state = .stopped
        try? service.input.close()
        service.process.terminate()
        failPending()
    }

    /// Reads the capture at `file`, which is deleted once the service is done
    /// with it. `answer` gets the text, or nil when the service could not
    /// read it or missed `deadline`; a late service just finishes quietly.
    func read(_ file: URL, deadline: TimeInterval, answer: @escaping @MainActor (String?) -> Void) {
        let once = OnceAnswer(answer)
        let id = nextID
        guard state == .ready, let service, let line = ReaderProtocol.request(id: id, file: file) else {
            discard(file)
            once.give(nil)
            return
        }
        do {
            try service.input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            // The service is gone; the end of its output follows.
            discard(file)
            once.give(nil)
            return
        }
        nextID += 1
        pending[id] = Pending(file: file, answer: once, sent: Date())
        state = .reading
        let process = service.process
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            MainActor.assumeIsolated {
                guard once.give(nil) else { return }
                self?.log.info("Read \(id) missed its deadline; the fast engine answered.")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readLimit) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.service?.process === process, self.pending[id] != nil else { return }
                self.log.error("Read \(id) took over \(Int(Self.readLimit))s; stopping the reader.")
                process.terminate()
            }
        }
    }

    private func received(_ data: Data, from process: Process) {
        guard let service, service.process === process else { return }
        for line in service.lines.append(data) {
            switch ReaderProtocol.parseReply(line) {
            case .ready:
                guard state == .loading else { continue }
                state = .ready
                failures = 0
                lastFailure = nil
                log.notice("Reader ready after \(Date().timeIntervalSince(service.launched), format: .fixed(precision: 1))s, \(String(describing: self.engine), privacy: .public) engine.")
            case .read(let id, let text):
                guard let request = pending.removeValue(forKey: id) else { continue }
                discard(request.file)
                if pending.isEmpty, state == .reading { state = .ready }
                let took = Date().timeIntervalSince(request.sent)
                log.info("Read \(id) in \(took, format: .fixed(precision: 2))s\(text == nil ? ", unreadable" : "", privacy: .public).")
                request.answer.give(text)
            case .failed:
                service.failed = true
                log.error("The reader's \(String(describing: self.engine), privacy: .public) engine failed.")
            case nil:
                continue
            }
        }
    }

    private func ended(_ process: Process) {
        guard let service, service.process === process else { return }
        self.service = nil
        try? service.input.close()
        // Exiting while idle is the service giving memory back, not a failure.
        let failed = service.failed || state == .loading || !pending.isEmpty
        state = .stopped
        failPending()
        guard failed else {
            log.info("Reader ended.")
            return
        }
        // An engine that reported failing hands over to the next, in a fresh
        // process, right away. Past the last one it is a failure, and the
        // retry starts over from the best engine. A service that died without
        // a word — out of memory, say — says nothing against its engine.
        if service.failed {
            if let next = engine.next {
                engine = next
                log.notice("Reader ended; starting the \(String(describing: next), privacy: .public) engine.")
                start()
                return
            }
            engine = .current
        }
        recordFailure()
        log.notice("Reader ended with failure \(self.failures) in a row.")
    }

    private func recordFailure() {
        failures += 1
        lastFailure = Date()
    }

    private func failPending() {
        let requests = pending.values
        pending = [:]
        for request in requests {
            discard(request.file)
            request.answer.give(nil)
        }
    }

    private func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private final class Service {
        let process: Process
        let input: FileHandle
        let launched = Date()
        var lines = LineBuffer()
        var failed = false

        init(process: Process, input: FileHandle) {
            self.process = process
            self.input = input
        }
    }

    private struct Pending {
        let file: URL
        let answer: OnceAnswer
        let sent: Date
    }
}

/// An answer given once: by the service or by the deadline, whichever comes first.
@MainActor
final class OnceAnswer {
    private var answer: (@MainActor (String?) -> Void)?

    init(_ answer: @escaping @MainActor (String?) -> Void) {
        self.answer = answer
    }

    @discardableResult
    func give(_ text: String?) -> Bool {
        guard let answer else { return false }
        self.answer = nil
        answer(text)
        return true
    }
}
