import Foundation

/// What the reader service says, one line at a time.
enum ReaderMessage: Equatable {
    /// Models loaded: captures can come.
    case ready
    /// Models could not be loaded; the service exits.
    case failed
    /// The text read from request `id`, or nil when it could not be read.
    case read(id: Int, text: String?)
}

/// The line protocol between ScreenHere and its reader service. A request is
/// `id⇥path`, a reply `id⇥ok⇥base64` or `id⇥fail`: recognised text spans
/// lines, and encoded it cannot split a reply in two.
enum ReaderProtocol {
    static let ready = "ready"
    static let failed = "failed"

    /// Nil when the path itself would break the framing.
    static func request(id: Int, file: URL) -> String? {
        let path = file.path
        guard id >= 0, !path.isEmpty, !path.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) else {
            return nil
        }
        return "\(id)\t\(path)"
    }

    static func parseRequest(_ line: String) -> (id: Int, path: String)? {
        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, let id = Int(fields[0]), id >= 0, !fields[1].isEmpty else { return nil }
        return (id, String(fields[1]))
    }

    static func reply(id: Int, text: String?) -> String {
        guard let text else { return "\(id)\tfail" }
        return "\(id)\tok\t\(Data(text.utf8).base64EncodedString())"
    }

    static func parseReply(_ line: String) -> ReaderMessage? {
        switch line {
        case ready: return .ready
        case failed: return .failed
        default: break
        }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2, let id = Int(fields[0]), id >= 0 else { return nil }
        switch (fields[1], fields.count) {
        case ("fail", 2):
            return .read(id: id, text: nil)
        case ("ok", 3):
            guard let data = Data(base64Encoded: String(fields[2])) else { return nil }
            return .read(id: id, text: String(decoding: data, as: UTF8.self))
        default:
            return nil
        }
    }
}

/// Splits bytes read from a pipe, in whatever chunks they come, into lines.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }
}
