import AppKit

enum BlurPrefs {
    static let enabledKey = "BlurEnabled"
    static let othersKey = "BlurOtherScreensEnabled"
}

/// Frosts the screen, so what is on it cannot be read from across the desk.
/// ⇧⌘9 pulls the frost over every display at once, and an option frosts the
/// displays the pointer is not on by itself. The frost is the window server's
/// own blur of what is behind a window: nothing is captured, nothing is
/// recorded, and what is behind it stays live and in place.
@MainActor
final class ScreenBlur: ObservableObject {
    static let shared = ScreenBlur()

    /// The feature, and with it ⇧⌘9.
    @Published private(set) var isEnabled = false
    /// The frost is down over everything, until ⇧⌘9 again.
    @Published private(set) var isCurtain = false
    /// Frost the displays the pointer is away from, on its own.
    @Published private(set) var blursOthers = false
    /// ⇧⌘9 is registered by another app.
    @Published private(set) var shortcutUnavailable = false

    /// A screen stays clear for a moment after the pointer leaves it: glancing
    /// at the other screen must not frost it in your face.
    static let delay: TimeInterval = 1.5
    /// How often the pointer is looked at. Reading it costs nothing, and the
    /// work only happens when the answer changed.
    private static let tick: TimeInterval = 0.2
    private static let fadeIn: TimeInterval = 0.35
    private static let fadeOut: TimeInterval = 0.18

    private let registrar = HotkeyRegistrar(signature: HotkeyRegistrar.blurSignature)
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    /// When the pointer was last on each display.
    private var lastSeen: [CGDirectDisplayID: Date] = [:]
    private var covered: Set<CGDirectDisplayID> = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?

    /// The displays to cover: every one the pointer has been away from for
    /// `delay`. Nothing with a single display — there is no other screen —
    /// and nothing while the pointer is on none of them, which is no reason
    /// to frost the one being used.
    static func covered(displays: [DisplayInfo], pointer: CGPoint,
                        lastSeen: [CGDirectDisplayID: Date], now: Date,
                        delay: TimeInterval) -> Set<CGDirectDisplayID> {
        guard displays.count > 1,
              let under = displays.first(where: { $0.bounds.contains(pointer) })?.id
        else { return [] }
        return Set(displays.map(\.id).filter { id in
            id != under && now.timeIntervalSince(lastSeen[id] ?? .distantPast) >= delay
        })
    }

    func activate() {
        isEnabled = UserDefaults.standard.bool(forKey: BlurPrefs.enabledKey)
        blursOthers = UserDefaults.standard.bool(forKey: BlurPrefs.othersKey)
        update()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: BlurPrefs.enabledKey)
        isEnabled = on
        // Switching the feature off lifts the frost with it; nothing should
        // be left over a screen by a shortcut that no longer answers.
        if !on { isCurtain = false }
        update()
    }

    func setBlursOthers(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: BlurPrefs.othersKey)
        blursOthers = on
        update()
    }

    /// ⇧⌘9: the frost over every display, and off again.
    func toggleCurtain() {
        guard isEnabled else { return }
        isCurtain.toggle()
        update()
    }

    /// Documentation shots only: show a state without registering, saving
    /// or frosting anything.
    func pose(enabled: Bool, blursOthers: Bool) {
        isEnabled = enabled
        self.blursOthers = blursOthers
    }

    /// Takes the frost off every screen and gives ⇧⌘9 back — at quit, so no
    /// overlay outlives the app that owns it.
    func stop() {
        registrar.unbindAll()
        isCurtain = false
        timer?.invalidate()
        timer = nil
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
        covered.removeAll()
    }

    /// Brings the shortcut, the pointer timer and the overlays in line with
    /// what is switched on.
    private func update() {
        registrar.unbindAll()
        shortcutUnavailable = isEnabled && !registrar.bind([.blurCurtain]) { _ in
            MainActor.assumeIsolated { ScreenBlur.shared.toggleCurtain() }
        }

        if isEnabled && blursOthers {
            if timer == nil {
                // A plain scheduled timer stops while a menu is open or a
                // window is being dragged, which is exactly when the pointer
                // changes screens.
                let timer = Timer(timeInterval: Self.tick, repeats: true) { _ in
                    MainActor.assumeIsolated { self.sample() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            timer?.invalidate()
            timer = nil
            lastSeen.removeAll()
        }

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                // A display that moved or changed size keeps its identifier,
                // so the overlays are built again rather than resized.
                MainActor.assumeIsolated {
                    for window in self.windows.values { window.orderOut(nil) }
                    self.windows.removeAll()
                    self.covered.removeAll()
                    self.sample()
                }
            }
        }
        sample()
    }

    private func sample() {
        let displays = CursorDisplay.activeDisplays()
        guard isEnabled else { return apply([]) }
        if isCurtain { return apply(Set(displays.map(\.id))) }
        guard blursOthers else { return apply([]) }

        let pointer = CursorDisplay.cursorLocation()
        let now = Date()
        if let under = displays.first(where: { $0.bounds.contains(pointer) })?.id {
            lastSeen[under] = now
        }
        apply(Self.covered(displays: displays, pointer: pointer,
                           lastSeen: lastSeen, now: now, delay: Self.delay))
    }

    private func apply(_ wanted: Set<CGDirectDisplayID>) {
        guard wanted != covered else { return }
        covered = wanted
        for (id, window) in windows where !wanted.contains(id) {
            windows[id] = nil
            fade(window, to: 0, over: Self.fadeOut) { window.orderOut(nil) }
        }
        for id in wanted where windows[id] == nil {
            guard let screen = Self.screen(for: id) else { continue }
            let window = Self.overlay(over: screen)
            windows[id] = window
            window.orderFrontRegardless()
            fade(window, to: 1, over: Self.fadeIn)
        }
    }

    private func fade(_ window: NSWindow, to alpha: CGFloat,
                      over duration: TimeInterval, then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        } completionHandler: {
            then?()
        }
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value == id
        }
    }

    /// A window over the whole display, above the menu bar and over a
    /// full-screen app, that no click can reach.
    private static func overlay(over screen: NSScreen) -> NSWindow {
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        let frost = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        frost.material = .fullScreenUI
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.autoresizingMask = [.width, .height]
        // The frost alone still leaves shapes and colours; a thin shade over
        // it is what makes a window unreadable rather than merely soft.
        let shade = NSView(frame: frost.bounds)
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        shade.autoresizingMask = [.width, .height]
        frost.addSubview(shade)
        panel.contentView = frost
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}
