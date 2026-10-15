import AppKit
import CoreImage
import ScreenCaptureKit

/// A blurred picture of a display, taken the moment the frost comes down.
///
/// A still picture rather than the window server's own behind-window blur:
/// that one is a tinted sheet laid over the screen, not a blur of what is on
/// it, and it drops out while macOS slides between desktops — the one moment
/// a frost must not lift. The picture stays in memory, is never written
/// anywhere, and goes when the frost does.
@available(macOS 14.0, *)
enum ScreenShade {
    /// The picture is taken small: throwing away three pixels in four is half
    /// the blur, and the other half is cheaper on what is left.
    private static let scale: CGFloat = 0.25
    private static let radius: Double = 12

    private static let context = CIContext()
    /// Kept between presses: asking macOS what is shareable costs ~60 ms, and
    /// that is 60 ms of unfrosted screen.
    private static var displays: [SCDisplay] = []
    private static var ourselves: SCRunningApplication?

    /// Looked up ahead of the first press, so it does not pay for it.
    static func warm() async {
        _ = await shareable()
    }

    static func blurred(display id: CGDirectDisplayID) async -> NSImage? {
        guard let display = await find(id) else { return nil }
        let width = Int(CGFloat(display.width) * scale)
        let height = Int(CGFloat(display.height) * scale)
        guard width > 0, height > 0 else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        // Our own windows are left out, so a frost already on screen can
        // never end up inside the picture of the next one.
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [ourselves].compactMap { $0 },
                                     exceptingWindows: [])
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                     configuration: configuration)
        else { return nil }
        return blur(shot)
    }

    /// A gaussian, held in to the edges: without the clamp the blur fades
    /// into transparency at the border and the frost leaks at the sides.
    private static func blur(_ image: CGImage) -> NSImage? {
        let source = CIImage(cgImage: image)
        guard let blurred = source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: source.extent) as CIImage?,
            let output = context.createCGImage(blurred, from: source.extent)
        else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: image.width, height: image.height))
    }

    private static func find(_ id: CGDirectDisplayID) async -> SCDisplay? {
        if let display = displays.first(where: { $0.displayID == id }) { return display }
        return await shareable()?.displays.first { $0.displayID == id }
    }

    private static func shareable() async -> SCShareableContent? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return nil }
        displays = content.displays
        ourselves = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        return content
    }
}
