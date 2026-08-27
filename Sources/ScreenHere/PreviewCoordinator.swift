import AppKit

/// Places the capture preview on the display the capture came from.
///
/// Which display that is comes from the pointer: for ScreenHere's own captures
/// that is the definition of the feature, and for a ⇧⌘4 selection the pointer
/// is on the screen the region was drawn on. One rule, every path.
@MainActor
enum PreviewCoordinator {

    /// Just a preference read; the panel samples it off the main actor.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreviewPrefs.enabledKey)
    }

    static func present(image: NSImage, file: URL?) {
        guard isEnabled, let screen = screenUnderPointer() else { return }
        CapturePreview.shared.show(image: image, file: file, on: screen)
    }

    /// Somewhere on disk, so a clipboard capture can still be dragged out as a
    /// file the way macOS's own preview allows.
    static func temporaryCopy(of image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenHere-\(UUID().uuidString.prefix(8)).png")
        try? png.write(to: url)
        return url
    }

    /// Pure: which display a `-D<n>` index refers to. Kept because it is the
    /// decision the capture itself rests on, and worth pinning by test.
    nonisolated static func displayID(forCaptureIndex index: Int,
                                      among displays: [DisplayInfo]) -> CGDirectDisplayID? {
        guard displays.indices.contains(index - 1) else { return nil }
        return displays[index - 1].id
    }

    private static func screenUnderPointer() -> NSScreen? {
        let point = CursorDisplay.cursorLocation()
        let displays = CursorDisplay.activeDisplays()
        guard let id = displayID(forCaptureIndex:
                                    CursorDisplay.captureIndex(for: point, in: displays,
                                                               mainDisplayID: CGMainDisplayID()),
                                 among: displays) else { return NSScreen.main }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value == id
        } ?? NSScreen.main
    }
}

enum PreviewPrefs {
    static let enabledKey = "ShowPreviewOnCapturedScreen"
}
