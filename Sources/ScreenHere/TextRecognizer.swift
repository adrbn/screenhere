import AppKit
import ImageIO
import Vision

/// Vision text recognition, on device. Nothing leaves the Mac.
enum TextRecognizer {
    enum Level { case accurate, fast }

    /// Recognised lines in Vision's reading order, joined by newlines.
    static func recognize(_ image: CGImage, level: Level) throws -> String {
        let request = request(level: level)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return text(of: request)
    }

    /// `revision` nil is Vision's current one.
    static func request(level: Level, revision: Int? = nil) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        // Before the languages: which ones are supported depends on it.
        if let revision { request.revision = revision }
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = level == .accurate
        request.recognitionLanguages = languages(for: request)
        return request
    }

    static func text(of request: VNRecognizeTextRequest) -> String {
        (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func languages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        return RecognitionLanguages.pick(preferred: Locale.preferredLanguages, supported: supported)
    }

    /// A capture's pixels, read in full: the file may be deleted before they
    /// are used.
    static func image(at file: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// Accurate recognition that holds on to its request and handler — and with
/// them Vision's loaded models — for as long as it lives.
final class LastingRecognizer: TextEngine {
    private let request: VNRecognizeTextRequest
    private let handler = VNSequenceRequestHandler()

    init(engine: ReaderEngine) {
        switch engine {
        case .current: request = TextRecognizer.request(level: .accurate)
        case .previous: request = TextRecognizer.request(level: .accurate, revision: VNRecognizeTextRequestRevision2)
        }
    }

    func recognize(_ image: CGImage) throws -> String {
        try handler.perform([request], on: image)
        return TextRecognizer.text(of: request)
    }
}
