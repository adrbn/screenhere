import Foundation

/// Which languages to ask Vision for: the user's own, then English.
enum RecognitionLanguages {
    static func pick(preferred: [String], supported: [String]) -> [String] {
        var picked: [String] = []
        for tag in preferred + ["en-US"] {
            if let match = match(tag, in: supported), !picked.contains(match) {
                picked.append(match)
            }
        }
        return picked
    }

    /// Exact tag first, then language plus script ("zh-Hant-TW" -> "zh-Hant"),
    /// then language alone ("fr-CA" -> "fr-FR").
    private static func match(_ tag: String, in supported: [String]) -> String? {
        if supported.contains(tag) { return tag }
        let parts = tag.split(separator: "-").map(String.init)
        guard let language = parts.first else { return nil }
        if parts.count > 1, parts[1].count == 4 {
            let prefix = "\(language)-\(parts[1])"
            if let hit = supported.first(where: { $0 == prefix || $0.hasPrefix(prefix + "-") }) {
                return hit
            }
        }
        return supported.first { $0.split(separator: "-").first.map(String.init) == language }
    }
}

/// What ScreenHere's reader service is doing.
enum ReaderState: Equatable {
    case stopped
    /// Launched, loading Vision's accurate models — a compile when their cache
    /// is stale.
    case loading
    case ready
    case reading
}

/// Vision's accurate engines a reader service can run, best first.
///
/// On the macOS 27 beta the Neural Engine sometimes refuses the current model
/// for a while — loaded or not, in every process — while the previous one
/// still loads and reads. A process where one failed stays broken, so each
/// engine gets a service of its own.
enum ReaderEngine: Equatable, CaseIterable {
    /// Vision's current accurate model.
    case current
    /// The one before it: fewer languages, English and French among them.
    case previous

    /// What follows the reader argument.
    var arguments: [String] {
        switch self {
        case .current: return []
        case .previous: return ["previous"]
        }
    }

    init?(arguments: [String]) {
        guard let engine = Self.allCases.first(where: { $0.arguments == arguments }) else { return nil }
        self = engine
    }

    /// The engine to start once this one has failed; nil past the last.
    var next: ReaderEngine? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}

/// Which engine a capture runs on.
///
/// Vision's accurate recogniser loads its models once per process, and on the
/// macOS 27 beta a fresh process often recompiles them first: 40–110s, during
/// which every other recognition in that process waits. A process that stays
/// up keeps them loaded and never pays it again. So the accurate engine lives
/// in one long-lived reader service, and captures only go to it while it is
/// ready. Otherwise the fast engine answers — instant, with the odd misread —
/// in ScreenHere itself.
enum RecognitionPlan: Equatable {
    case accurate
    case fast
    case fastAndStart

    /// How long a reader that failed `failures` times in a row is left alone
    /// before another is started: 2 minutes, then 10, then 50, then hourly.
    /// Every failed load has cost a model compile first, and the beta's Neural
    /// Engine compiler sometimes refuses every model for a while.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let delay = 120 * pow(5, Double(min(failures, 4) - 1))
        return min(delay, 3_600)
    }

    static func decide(reader: ReaderState, failures: Int, lastFailure: Date?, now: Date) -> RecognitionPlan {
        switch reader {
        case .ready:
            return .accurate
        case .loading, .reading:
            return .fast
        case .stopped:
            if let lastFailure, now.timeIntervalSince(lastFailure) < retryDelay(afterFailures: failures) {
                return .fast
            }
            return .fastAndStart
        }
    }
}

enum TextCaptureStrings {
    static func copied(_ text: String) -> String {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        switch words {
        case 0: return "No text found"
        case 1: return "Copied 1 word"
        default: return "Copied \(words) words"
        }
    }
}
