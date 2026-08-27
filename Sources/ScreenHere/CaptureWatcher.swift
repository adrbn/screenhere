import AppKit

/// Notices any screenshot the Mac takes, whoever asked for it.
///
/// The preview option started out hooked to ScreenHere's own shortcuts, which
/// left a hole: turning macOS's preview off removes the confirmation for ⇧⌘4,
/// ⇧⌘5 and the Screenshot app too, and nothing replaced it. A capture taken
/// with ⇧⌘4 straight to the clipboard then produced no file, no preview and no
/// sign it had worked at all.
///
/// So the watcher covers every path. Two sources, because macOS offers no
/// single signal:
///
///   - a file destination: the folder the user chose. Reliable, and anything
///     appearing there is a capture by definition.
///   - the clipboard: the change counter, filtered by what the payload looks
///     like. This one is a judgement call rather than a fact — see below.
@MainActor
final class CaptureWatcher {
    static let shared = CaptureWatcher()

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var seenFiles: Set<URL> = []
    private var primed = false

    /// A screenshot on the pasteboard is bare image data. Anything that also
    /// carries markup, an address or a file reference came from copying
    /// something, not from capturing the screen — and an image arriving over
    /// Universal Clipboard was not taken on this Mac at all.
    nonisolated static func looksLikeCapture(types: [NSPasteboard.PasteboardType]) -> Bool {
        let raw = Set(types.map(\.rawValue))
        let hasImage = raw.contains("public.png") || raw.contains("public.tiff")
        guard hasImage else { return false }
        let disqualifying = ["public.html", "public.url", "public.file-url",
                             "public.rtf", "com.apple.is-remote-clipboard"]
        return !disqualifying.contains { raw.contains($0) }
    }

    func start() {
        stop()
        primed = false
        lastChangeCount = NSPasteboard.general.changeCount
        seenFiles = Set(CaptureLocator.candidates(in: destinationFolder()).map(\.url))
        primed = true

        // Polling rather than a filesystem source: it has to cover the
        // pasteboard too, and half a second is imperceptible for a preview.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard primed, PreviewCoordinator.isEnabled else { return }
        if ScreenshotSettings.current == "Clipboard" { checkPasteboard() } else { checkFolder() }
    }

    private func checkPasteboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount

        guard let item = board.pasteboardItems?.first,
              Self.looksLikeCapture(types: item.types),
              let data = board.data(forType: .tiff) ?? board.data(forType: .png),
              let rep = NSBitmapImageRep(data: data) else { return }

        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        PreviewCoordinator.present(image: image, file: PreviewCoordinator.temporaryCopy(of: image))
    }

    private func checkFolder() {
        let candidates = CaptureLocator.candidates(in: destinationFolder())
        let fresh = candidates.filter { !seenFiles.contains($0.url) }
        seenFiles = Set(candidates.map(\.url))

        // Newest of whatever appeared, and only if it is genuinely recent: a
        // folder that gains an old file (a copy, a sync) is not a capture.
        guard let newest = fresh.max(by: { $0.created < $1.created }),
              Date().timeIntervalSince(newest.created) < 5,
              let image = NSImage(contentsOf: newest.url) else { return }
        PreviewCoordinator.present(image: image, file: newest.url)
    }

    private func destinationFolder() -> URL {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        let path = defaults?.string(forKey: "location") ?? "~/Desktop"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
