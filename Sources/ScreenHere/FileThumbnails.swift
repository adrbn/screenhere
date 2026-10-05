import AppKit
import QuickLookThumbnailing

/// Quick Look's picture of a copied file — the PDF's first page, the photo
/// itself, and the file type's icon when there is nothing to preview, which
/// Quick Look falls back to on its own.
///
/// Pictures arrive after the row is already drawn, like the link previews':
/// asking costs nothing, waiting would hold the list up.
@MainActor
final class FileThumbnails: ObservableObject {
    static let shared = FileThumbnails()
    private static let side: CGFloat = 44

    @Published private(set) var ready: [String: NSImage] = [:]
    /// Asked once per file: one Quick Look could not picture has nothing to
    /// picture, and a row is drawn again on every keystroke.
    private var asked: Set<String> = []

    func thumbnail(for file: ClipFile) -> NSImage? { ready[file.path] }

    func want(_ file: ClipFile) {
        guard !asked.contains(file.path) else { return }
        asked.insert(file.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: CGSize(width: Self.side, height: Self.side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] picture, _ in
            guard let picture else { return }
            let image = NSImage(cgImage: picture.cgImage, size: .zero)
            Task { @MainActor in self?.ready[file.path] = image }
        }
    }

    func clear() {
        ready = [:]
        asked = []
        posed = false
    }

    /// Documentation shots only: pictures for files that are not on this Mac,
    /// whose rows must still read as within reach.
    private(set) var posed = false

    func pose(_ pictures: [String: NSImage]) {
        ready = pictures
        asked = Set(pictures.keys)
        posed = true
    }
}
