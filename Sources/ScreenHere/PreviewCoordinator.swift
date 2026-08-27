import AppKit

/// Bridges a finished capture to the preview shown on the captured display.
///
/// The awkward part is finding the image. `screencapture -p` obeys the user's
/// settings, so it chooses the destination and the filename and reports
/// neither. Rather than take that decision back — delegating is what keeps
/// ScreenHere honest about format, folder and sound — the file is recognised by
/// having appeared in the destination folder just after the capture was asked
/// for. When the destination is the clipboard there is no file at all, and the
/// image is read straight from the pasteboard.
@MainActor
enum PreviewCoordinator {
    /// How long to wait for `screencapture` to finish writing.
    private static let window: TimeInterval = 2.5

    /// Just a preference read; the panel samples it off the main actor.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreviewPrefs.enabledKey)
    }

    /// Called right after a capture is launched, with the display it targeted.
    static func captureStarted(displayIndex: Int) {
        guard isEnabled else { return }
        let started = Date()
        let screen = self.screen(forCaptureIndex: displayIndex)

        // Poll briefly: screencapture writes asynchronously, and the clipboard
        // is not populated the instant the process is spawned either.
        var elapsed: TimeInterval = 0
        let step: TimeInterval = 0.2
        Timer.scheduledTimer(withTimeInterval: step, repeats: true) { timer in
            elapsed += step
            Task { @MainActor in
                if let found = locate(after: started) {
                    timer.invalidate()
                    if let screen {
                        CapturePreview.shared.show(image: found.image, file: found.file, on: screen)
                    }
                } else if elapsed >= window {
                    timer.invalidate()
                }
            }
        }
    }

    // MARK: - Finding the capture

    private struct Found {
        let image: NSImage
        let file: URL?
    }

    private static func locate(after started: Date) -> Found? {
        if ScreenshotSettings.current == "Clipboard" {
            guard let image = pasteboardImage() else { return nil }
            // Dragging needs something on disk; the pasteboard alone cannot be
            // dropped into another app as a file.
            return Found(image: image, file: temporaryCopy(of: image))
        }
        guard let folder = destinationFolder(),
              let url = CaptureLocator.produced(among: CaptureLocator.candidates(in: folder),
                                                after: started, within: window),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return Found(image: image, file: url)
    }

    private static func pasteboardImage() -> NSImage? {
        let board = NSPasteboard.general
        guard let data = board.data(forType: .tiff) ?? board.data(forType: .png),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    private static func temporaryCopy(of image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHere-\(UUID().uuidString.prefix(8)).png")
        try? png.write(to: url)
        return url
    }

    private static func destinationFolder() -> URL? {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        let path = defaults?.string(forKey: "location") ?? "~/Desktop"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: - Which screen

    /// `displayIndex` is the 1-based `screencapture -D` index, i.e. a position
    /// in `CGGetActiveDisplayList`. Map it back to the NSScreen that drew it.
    /// Pure: which display a `-D<n>` index refers to. This is the decision the
    /// whole feature rests on — the preview belongs on the screen that was
    /// captured, not on the main one.
    nonisolated static func displayID(forCaptureIndex index: Int,
                                      among displays: [DisplayInfo]) -> CGDirectDisplayID? {
        guard displays.indices.contains(index - 1) else { return nil }
        return displays[index - 1].id
    }

    private static func screen(forCaptureIndex index: Int) -> NSScreen? {
        guard let id = displayID(forCaptureIndex: index,
                                 among: CursorDisplay.activeDisplays()) else { return NSScreen.main }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value == id
        } ?? NSScreen.main
    }
}

enum PreviewPrefs {
    static let enabledKey = "ShowPreviewOnCapturedScreen"
}
