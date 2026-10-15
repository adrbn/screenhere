import AppKit

enum BlurPrefs {
    static let enabledKey = "BlurEnabled"
    static let othersKey = "BlurOtherScreensEnabled"
    static let holdsKey = "BlurHoldsDisplayEnabled"
}

/// Frosts the screen, so what is on it cannot be read from across the desk.
/// ⇧⌘9 pulls the frost over every display at once, and an option frosts the
/// displays the pointer is not on by itself. The frost is a blurred picture of
/// the screen taken the moment it comes down — see `ScreenShade` — kept in
/// memory and thrown away with the frost.
@MainActor
final class ScreenBlur: ObservableObject {
    static let shared = ScreenBlur()

    /// The feature, and with it ⇧⌘9.
    @Published private(set) var isEnabled = false
    /// The frost is down over everything, until ⇧⌘9 again.
    @Published private(set) var isCurtain = false
    /// Frost the displays the pointer is away from, on its own.
    @Published private(set) var blursOthers = false
    /// Hold the displays the curtain covers, so macOS cannot slide to another
    /// desktop while they are frosted.
    @Published private(set) var holdsDisplay = false
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
    /// Bumped on every change, so a picture that arrives late is dropped.
    private var generation = 0
    /// Displays taken over for the curtain, to give back when it lifts.
    private var seized: Set<CGDirectDisplayID> = []
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
        holdsDisplay = UserDefaults.standard.bool(forKey: BlurPrefs.holdsKey)
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

    func setHoldsDisplay(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: BlurPrefs.holdsKey)
        holdsDisplay = on
        // Whether a cover holds its display is settled when it is made, so
        // any already on screen are taken down and made again.
        apply([])
        update()
    }

    /// ⇧⌘9: the frost over every display, and off again.
    func toggleCurtain() {
        guard isEnabled else { return }
        isCurtain.toggle()
        // The curtain's covers hold the display; the automatic ones do not,
        // so any already on screen are taken down and made again.
        apply([])
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
        release()
    }

    /// Brings the shortcut, the pointer timer and the overlays in line with
    /// what is switched on.
    private func update() {
        registrar.unbindAll()
        shortcutUnavailable = isEnabled && !registrar.bind([.blurCurtain]) { _ in
            MainActor.assumeIsolated { ScreenBlur.shared.toggleCurtain() }
        }
        if isEnabled, #available(macOS 14.0, *) { Task { await ScreenShade.warm() } }

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
                // Switching desktops sets this off as well, so the overlays
                // are moved rather than rebuilt: a frost that blinks off
                // mid-swipe shows what it is there to hide.
                MainActor.assumeIsolated {
                    for (id, window) in self.windows {
                        guard let screen = Self.screen(for: id) else { continue }
                        window.setFrame(screen.frame, display: true)
                    }
                    // A display that really went away is simply missing from
                    // the next sample, and its cover goes with it.
                    self.sample()
                }
            }
        }
        sample()
    }

    private func sample() {
        let displays = CursorDisplay.activeDisplays()
        // Sliding between desktops makes the display list come back empty for
        // an instant. Taking that as "no screens" drops the frost in the
        // middle of the swipe, which is the one moment it must not lift.
        guard !displays.isEmpty else { return }
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
        generation += 1
        let generation = self.generation
        let holding = isCurtain && holdsDisplay
        // Given back while the frost still hides the screen: leaving capture
        // blanks the display for an instant, and that instant belongs behind
        // the frost rather than in front of it.
        if wanted.isEmpty { release() }
        for (id, window) in windows where !wanted.contains(id) {
            windows[id] = nil
            fade(window, to: 0, over: Self.fadeOut) { window.orderOut(nil) }
        }
        for id in wanted where windows[id] == nil {
            guard let screen = Self.screen(for: id) else { continue }
            guard #available(macOS 14.0, *) else {
                frost(nil, over: screen, id: id)
                continue
            }
            // Nothing is put on screen until there is a picture to put there.
            Task { [weak self] in
                let shot = await ScreenShade.shot(display: id)
                guard let self, self.generation == generation,
                      self.covered.contains(id), self.windows[id] == nil else { return }
                if holding, let shot { self.lower(shot, over: screen, id: id) }
                else { self.frost(shot?.frosted, over: screen, id: id) }
            }
        }
    }

    /// The curtain, which holds the display so the desktop cannot slide.
    ///
    /// The display is taken **before** the window is made: a window that
    /// already existed is not composed on a held display — it goes black,
    /// which is what measuring it showed. So the order is take, then make.
    ///
    /// Taking it blanks the screen, so the sharp picture goes up in that same
    /// breath and the screen looks untouched; the frost then fades in over
    /// it. Nothing flashes.
    @available(macOS 14.0, *)
    private func lower(_ shot: (sharp: NSImage, frosted: NSImage),
                       over screen: NSScreen, id: CGDirectDisplayID) {
        let held = CGDisplayCaptureWithOptions(id, .noFill) == .success
        if held { seized.insert(id) }
        let window = Self.overlay(over: screen)
        // A held display composes nothing but windows of ours at this level.
        window.level = held ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                            : .screenSaver
        let view = Self.picture(shot.sharp, over: screen)
        window.contentView = view
        window.alphaValue = 1
        windows[id] = window
        window.orderFrontRegardless()

        let transition = CATransition()
        transition.type = .fade
        transition.duration = Self.fadeIn
        view.layer?.add(transition, forKey: "contents")
        view.image = shot.frosted
    }

    /// The automatic frost, which holds nothing: it is on all day, and a Mac
    /// whose desktops are stuck all day is worse than one that is not.
    private func frost(_ picture: NSImage?, over screen: NSScreen, id: CGDirectDisplayID) {
        let window = Self.overlay(over: screen)
        if let picture { window.contentView = Self.picture(picture, over: screen) }
        windows[id] = window
        window.orderFrontRegardless()
        fade(window, to: 1, over: Self.fadeIn)
    }

    /// Gives back every display the curtain held.
    private func release() {
        for id in seized { CGDisplayRelease(id) }
        seized.removeAll()
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

        // Until the picture arrives — and instead of it, before macOS 14 or
        // without Screen Recording — the window server's own frost. It is a
        // tinted sheet rather than a blur of the screen, but it hides.
        let frost = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        frost.material = .fullScreenUI
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.autoresizingMask = [.width, .height]
        panel.contentView = frost
        panel.setFrame(screen.frame, display: false)
        return panel
    }

    /// The blurred picture, filling the display whatever its own size — it is
    /// taken at a quarter of it.
    private static func picture(_ image: NSImage, over screen: NSScreen) -> NSImageView {
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.autoresizingMask = [.width, .height]
        return view
    }
}
