import AppKit

enum TextPrefs {
    static let copyTextKey = "CopyTextShortcutEnabled"
    static let historyKey = "ClipboardHistoryEnabled"
    static let linkPreviewsKey = "LinkPreviewsEnabled"
}

/// The clipboard history as the app sees it: whether it is on, what it holds,
/// and the one door through which ScreenHere writes to the clipboard.
@MainActor
final class ClipboardController: ObservableObject {
    static let shared = ClipboardController()

    @Published private(set) var history: ClipboardHistory = .empty
    @Published private(set) var isEnabled = false
    /// macOS 15.4+ asks before an app reads the clipboard in the background.
    /// History needs "Always Allow"; anything short of it is worth a row.
    @Published private(set) var needsPasteAccess = false

    private let watcher = ClipboardWatcher()
    private let store = ClipboardHistoryStore()
    private let images = ClipboardImageStore()
    /// Pictures are hashed, re-encoded and written off the main thread: a
    /// Retina screenshot as TIFF takes a noticeable moment.
    private let imageQueue = DispatchQueue(label: "com.screenhere.clipboard-images", qos: .utility)
    private let thumbnails = NSCache<NSString, NSImage>()
    private var pendingSave: DispatchWorkItem?
    /// The TIFF of the last picture put back on the clipboard, made on demand.
    private var tiffProvider: NSPasteboardItemDataProvider?
    /// Bumped by every clear, so a picture still being written when the
    /// history was cleared does not come back into it.
    private var generation = 0
    /// Pictures still to be read, the digests already asked for, and whether a
    /// reader is running: one picture at a time, so a list full of old
    /// screenshots does not start a reader per row.
    private var captionQueue: [ClipImage] = []
    private var captionsAsked: Set<String> = []
    private var readingCaption = false

    private init() {
        watcher.onCopy = { [weak self] copied, source in self?.handle(copied, source: source) }
    }

    /// Off unless the user turns it on: an update must never start recording
    /// everything someone copies without them asking for it.
    func activate() {
        isEnabled = UserDefaults.standard.bool(forKey: TextPrefs.historyKey)
        if isEnabled { loadHistory() }
        watch()
        refreshAccess()
    }

    /// Watches the pasteboard while something needs it: the history, or the
    /// clipboard shared with another device.
    func watch() {
        if isEnabled || SyncController.shared.isEnabled {
            if !watcher.isRunning { watcher.start() }
        } else {
            watcher.stop()
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: TextPrefs.historyKey)
        isEnabled = on
        if on { loadHistory() } else { flush() }
        watch()
        refreshAccess()
    }

    func refreshAccess() {
        guard isEnabled || SyncController.shared.isEnabled, #available(macOS 15.4, *) else {
            needsPasteAccess = false
            return
        }
        let behavior = NSPasteboard.general.accessBehavior
        needsPasteAccess = behavior == .ask || behavior == .alwaysDeny
    }

    /// Puts text on the clipboard and, when history is on, at its top.
    func write(_ text: String, source: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        watcher.ignore(changeCount: pasteboard.changeCount)
        if isEnabled { apply(history.adding(text, source: source, at: Date())) }
    }

    /// Puts an item back on the clipboard. False when what it points at is
    /// gone from disk: a missing picture takes its item with it, a missing
    /// file does not — an unplugged disk comes back, and its row says so.
    @discardableResult
    func copy(_ item: ClipItem) -> Bool {
        switch item.content {
        case .text(let text):
            write(text, source: item.source)
            return true
        case .image(let image):
            guard let data = images.data(for: image) else {
                remove(item)
                return false
            }
            let pasteboard = NSPasteboard.general
            tiffProvider = PasteboardImageWriter.write(data, format: image.format, to: pasteboard)
            watcher.ignore(changeCount: pasteboard.changeCount)
            if isEnabled { apply(history.adding(image: image, source: item.source, at: Date())) }
            return true
        case .files(let files):
            // Whatever is still there: two files copied, one deleted since,
            // and the one left is better than nothing.
            let present = files.filter(\.exists)
            guard !present.isEmpty else { return false }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(present.map { $0.url as NSURL })
            watcher.ignore(changeCount: pasteboard.changeCount)
            if isEnabled { apply(history.adding(files: files, source: item.source, at: Date())) }
            return true
        }
    }

    /// Puts a picture that came from the other device on the clipboard and,
    /// when history is on, at its top.
    func writeImage(_ png: Data, source: String?) {
        let pasteboard = NSPasteboard.general
        tiffProvider = PasteboardImageWriter.write(png, format: .png, to: pasteboard)
        watcher.ignore(changeCount: pasteboard.changeCount)
        guard isEnabled else { return }
        let images = self.images
        let generation = self.generation
        imageQueue.async {
            let image = try? images.ingest(png, type: "public.png")
            Task { @MainActor in
                guard let image, self.isEnabled, self.generation == generation else { return }
                self.apply(self.history.adding(image: image, source: source, at: Date()))
                self.wantCaption(for: image)
            }
        }
    }

    /// Reads the words in a picture, for its row's title and for the search.
    /// Asked for by a new copy and by the list as rows appear, so pictures
    /// copied before this existed get their words too. Once per picture.
    func wantCaption(for image: ClipImage) {
        guard isEnabled, image.caption == nil,
              captionsAsked.insert(image.digest).inserted else { return }
        captionQueue.append(image)
        readNextCaption()
    }

    private func readNextCaption() {
        guard !readingCaption, !captionQueue.isEmpty else { return }
        let image = captionQueue.removeFirst()
        readingCaption = true
        let images = self.images
        let generation = self.generation
        // Reading the file is off the main thread; the words then come back to
        // it, one picture at a time.
        imageQueue.async {
            let data = images.data(for: image)
            Task { @MainActor in
                guard let data, self.generation == generation else {
                    self.readingCaption = false
                    self.readNextCaption()
                    return
                }
                FastReader.read(data, background: true) { words in
                    self.readingCaption = false
                    if self.generation == generation {
                        let caption = words.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.apply(self.history.captioning(image.digest, with: caption))
                    }
                    self.readNextCaption()
                }
            }
        }
    }

    func thumbnail(for image: ClipImage) -> NSImage? {
        let key = image.digest as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let small = images.thumbnail(for: image) else { return nil }
        let thumbnail = NSImage(cgImage: small, size: .zero)
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    /// Where the picture sits on disk, so a row can be dragged into any app.
    /// Not checked for existence: the list asks for this on every redraw.
    func fileURL(for image: ClipImage) -> URL {
        images.fileURL(for: image)
    }

    /// A copy of the picture in the Downloads folder, where the Finder and the
    /// Dock show it. Nil when the picture is gone or the copy fails.
    @discardableResult
    func saveToDownloads(_ image: ClipImage) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory,
                                                       in: .userDomainMask).first
        else { return nil }
        return try? images.copy(image, into: downloads)
    }

    func remove(_ item: ClipItem) {
        apply(history.removing(item.id))
    }

    func clear() {
        generation += 1
        pendingSave?.cancel()
        pendingSave = nil
        history = .empty
        captionQueue.removeAll()
        captionsAsked.removeAll()
        store.delete()
        thumbnails.removeAllObjects()
        FileThumbnails.shared.clear()
        LinkPreviewController.shared.clear()
        let images = self.images
        imageQueue.async { images.deleteAll() }
    }

    /// Writes any pending change now — at quit and power-off.
    func flush() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        try? store.save(history)
    }

    /// Loads the list without entries whose picture went missing, and sweeps
    /// pictures nothing points at any more.
    private func loadHistory() {
        let images = self.images
        history = store.load().filtering { item in
            guard let image = item.image else { return true }
            return FileManager.default.fileExists(atPath: images.fileURL(for: image).path)
        }
        let keep = history.imageDigests
        imageQueue.async { images.prune(keeping: keep) }
        LinkPreviewController.shared.prune(keeping: history.links)
    }

    private func handle(_ copied: Copied, source: String?) {
        // The watcher also runs for the shared clipboard alone: the history
        // only takes what it is on for.
        let keeps = isEnabled
        switch copied {
        case .text(let text):
            if keeps { apply(history.adding(text, source: source, at: Date())) }
            SyncController.shared.localCopy(text: text)
        case .files(let urls):
            if keeps { apply(history.adding(files: urls.map { ClipFile(path: $0.path) }, source: source, at: Date())) }
        case .image(let data, let type):
            let images = self.images
            let generation = self.generation
            let shares = SyncController.shared.isConnected
            imageQueue.async {
                let image = keeps ? (try? images.ingest(data, type: type)) : nil
                // The other device is sent a PNG, whatever the copy came as.
                let png = !shares ? nil
                    : type == "public.png" ? data
                    : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                Task { @MainActor in
                    if let png { SyncController.shared.localCopy(png: png) }
                    // Turned off or cleared meanwhile: a file left behind is
                    // swept at the next load.
                    guard let image, self.isEnabled, self.generation == generation else { return }
                    self.apply(self.history.adding(image: image, source: source, at: Date()))
                    self.wantCaption(for: image)
                }
            }
        }
    }

    /// Publishes a new history, schedules its save, and deletes the pictures
    /// and link previews it no longer holds.
    private func apply(_ next: ClipboardHistory) {
        let dropped = history.imageDigests.subtracting(next.imageDigests)
        LinkPreviewController.shared.forget(history.links.subtracting(next.links), keeping: next.links)
        history = next
        scheduleSave()
        guard !dropped.isEmpty else { return }
        for digest in dropped { thumbnails.removeObject(forKey: digest as NSString) }
        let images = self.images
        imageQueue.async { images.remove(digests: dropped) }
    }

    /// Copies come in bursts; one write a couple of seconds after the last is
    /// plenty.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            try? self.store.save(self.history)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Documentation shots and previews only: show a history without watching
    /// or writing anything.
    func pose(_ history: ClipboardHistory, enabled: Bool, thumbnails: [String: NSImage] = [:]) {
        watcher.stop()
        self.history = history
        isEnabled = enabled
        for (digest, image) in thumbnails { self.thumbnails.setObject(image, forKey: digest as NSString) }
    }

    func openPasteAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:"
            + "com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Puts a picture on a pasteboard in its own format, with TIFF made only if a
/// pasting app asks for it: most take PNG or JPEG, and a Retina screenshot as
/// TIFF weighs tens of megabytes.
enum PasteboardImageWriter {
    /// The returned provider must outlive the pasteboard's contents.
    static func write(_ data: Data, format: ClipImage.Format, to pasteboard: NSPasteboard) -> NSPasteboardItemDataProvider {
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setData(data, forType: NSPasteboard.PasteboardType(format.pasteboardType))
        let provider = TIFFProvider(data: data)
        entry.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.writeObjects([entry])
        return provider
    }

    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        private let data: Data

        init(data: Data) {
            self.data = data
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation else { return }
            item.setData(tiff, forType: .tiff)
        }
    }
}

/// Binds ⇧⌘7 and ⇧⌘8 according to what is switched on. Each has its own
/// registrar, so one combination being taken by another app does not cost the
/// other.
@MainActor
final class TextShortcuts: ObservableObject {
    static let shared = TextShortcuts()

    @Published private(set) var copyTextEnabled = true
    /// A combination another app already registered.
    @Published private(set) var copyTextUnavailable = false
    @Published private(set) var historyUnavailable = false

    private let copyTextRegistrar = HotkeyRegistrar(signature: HotkeyRegistrar.textSignature)
    private let historyRegistrar = HotkeyRegistrar(signature: HotkeyRegistrar.textSignature)
    /// macOS assigns ⇧⌘7 to "Save picture of the Touch Bar as a file", and a
    /// system shortcut wins over ours: the press grabbed the Touch Bar.
    private let touchBarLease = SymbolicHotkeyLease(
        id: SymbolicHotkeyPlist.touchBarToFile, keyCode: 26, modifiers: 1_179_648)

    func activate() {
        copyTextEnabled = UserDefaults.standard.object(forKey: TextPrefs.copyTextKey) as? Bool ?? true
        rebind()
        updateReader()
    }

    /// The reader loads the accurate models as soon as ⇧⌘7 is on, so captures
    /// are not left to the fast engine — which misreads accents ("Ète à côte",
    /// "Dejà") and "Il" as "11".
    private func updateReader() {
        if copyTextEnabled { TextReader.shared.start() } else { TextReader.shared.stop() }
    }

    /// Gives borrowed system shortcuts back — at quit, power-off and before an
    /// update replaces the app. The next launch borrows them again.
    func releaseSystemShortcuts() {
        copyTextRegistrar.unbindAll()
        touchBarLease.release()
        TextReader.shared.stop()
    }

    func setCopyTextEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: TextPrefs.copyTextKey)
        copyTextEnabled = on
        rebind()
        updateReader()
    }

    func rebind() {
        copyTextRegistrar.unbindAll()
        historyRegistrar.unbindAll()
        if copyTextEnabled {
            let lease = touchBarLease.acquire()
            let bound = copyTextRegistrar.bind([.copyText]) { _ in
                MainActor.assumeIsolated { TextCapture.run() }
            }
            copyTextUnavailable = lease == .refused || !bound
        } else {
            touchBarLease.release()
            copyTextUnavailable = false
        }
        historyUnavailable = ClipboardController.shared.isEnabled
            && !historyRegistrar.bind([.clipboardHistory]) { _ in
                MainActor.assumeIsolated { HistoryPicker.shared.toggle() }
            }
    }
}
