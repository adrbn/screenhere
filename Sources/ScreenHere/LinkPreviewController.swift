import AppKit

/// Titles and icons for the links in the ⇧⌘8 list. Off unless the user turns
/// it on: a preview means visiting the link, and an update must never start
/// doing that on its own.
@MainActor
final class LinkPreviewController: ObservableObject {
    static let shared = LinkPreviewController()

    struct Shown {
        let title: String?
        let icon: NSImage?
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var shown: [String: Shown] = [:]

    /// Visits under way at once; the others wait their turn.
    static let maxVisits = 3

    private let store: LinkPreviewStore
    private let visitor: any LinkVisiting
    private let defaults: UserDefaults
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.screenhere.link-previews", qos: .utility)
    /// Links looked up since launch or the last clear, and when each may be
    /// looked up again: never once it has a preview, a day after an empty one.
    private var asked: [String: Date] = [:]
    private var waiting: [CopiedLink] = []
    private var running = 0
    /// Bumped by turning previews off and by clearing, so a visit under way
    /// then neither shows nor saves what it brings back.
    private var generation = 0

    init(store: LinkPreviewStore = LinkPreviewStore(), visitor: any LinkVisiting = LinkVisitor(),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.visitor = visitor
        self.defaults = defaults
        self.now = now
    }

    func activate() {
        isEnabled = defaults.bool(forKey: TextPrefs.linkPreviewsKey)
    }

    /// Off also deletes every preview kept so far.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: TextPrefs.linkPreviewsKey)
        isEnabled = on
        if !on { clear() }
    }

    func preview(for link: CopiedLink) -> Shown? {
        shown[LinkPreviewStore.key(for: link)]
    }

    /// A row showing `link` came on screen: shows its stored preview, and
    /// visits the link when there is none worth keeping. Never at copy time.
    func want(_ link: CopiedLink) {
        guard isEnabled, link.mayVisit else { return }
        let key = LinkPreviewStore.key(for: link)
        let now = self.now()
        if let again = asked[key], again >= now { return }
        asked[key] = .distantFuture
        let store = self.store
        let generation = self.generation
        queue.async {
            let stored = store.preview(for: key)
            let icon = stored?.hasIcon == true ? store.icon(for: key).map { NSImage(cgImage: $0, size: .zero) } : nil
            Task { @MainActor in
                // Not turned off, cleared or forgotten meanwhile.
                guard self.generation == generation, self.asked[key] != nil else { return }
                if let stored {
                    self.show(stored, icon: icon, key: key)
                    guard LinkPreviewStore.needsVisit(stored, now: now) else {
                        self.asked[key] = LinkPreviewStore.nextVisit(after: stored)
                        return
                    }
                }
                self.waiting.append(link)
                self.visitNext()
            }
        }
    }

    /// Links that left the history take their previews with them — unless a
    /// link still there shares one, being the same page but for tracking
    /// parameters or a fragment.
    func forget(_ gone: Set<CopiedLink>, keeping remaining: Set<CopiedLink>) {
        let keys = Set(gone.map(LinkPreviewStore.key(for:))).subtracting(remaining.map(LinkPreviewStore.key(for:)))
        guard !keys.isEmpty else { return }
        waiting.removeAll { keys.contains(LinkPreviewStore.key(for: $0)) }
        for key in keys {
            asked[key] = nil
            shown[key] = nil
        }
        let store = self.store
        queue.async { store.remove(keys: keys) }
    }

    /// Sweeps previews of links the history no longer holds.
    func prune(keeping links: Set<CopiedLink>) {
        let keys = Set(links.map(LinkPreviewStore.key(for:)))
        let store = self.store
        queue.async { store.prune(keeping: keys) }
    }

    func clear() {
        generation += 1
        waiting = []
        asked = [:]
        shown = [:]
        let store = self.store
        queue.async { store.deleteAll() }
    }

    private func visitNext() {
        while running < Self.maxVisits, !waiting.isEmpty {
            let link = waiting.removeFirst()
            let generation = self.generation
            running += 1
            Task {
                let (preview, icon) = await visitor.visit(link, now: now())
                running -= 1
                let key = LinkPreviewStore.key(for: link)
                // Not turned off, cleared or forgotten meanwhile.
                if self.generation == generation, asked[key] != nil {
                    let store = self.store
                    queue.async { try? store.save(preview, icon: icon, key: key) }
                    show(preview, icon: icon.flatMap(NSImage.init(data:)), key: key)
                    asked[key] = LinkPreviewStore.nextVisit(after: preview)
                }
                visitNext()
            }
        }
    }

    private func show(_ preview: LinkPreview, icon: NSImage?, key: String) {
        guard !preview.isEmpty else { return }
        shown[key] = Shown(title: preview.title, icon: icon)
    }
}
