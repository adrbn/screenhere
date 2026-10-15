import AppKit

enum BlurPrefs {
    static let enabledKey = "BlurEnabled"
    static let othersKey = "BlurOtherScreensEnabled"
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
        let curtain = isCurtain
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
            let window = Self.overlay(over: screen)
            windows[id] = window
            guard #available(macOS 14.0, *) else {
                show(window, over: id, seizing: false)
                continue
            }
            // The picture is taken before anything is on screen, and the
            // window stays empty — and invisible — until it is there.
            Task { [weak self] in
                let shade = await ScreenShade.blurred(display: id)
                guard let self, self.windows[id] === window else { return }
                if let shade { window.contentView = Self.picture(shade, over: screen) }
                self.show(window, over: id, seizing: curtain && shade != nil)
            }
        }
    }

    /// Sliding between desktops is animated by the window server, which draws
    /// none of our windows while it does — whatever their level, as measuring
    /// it showed — so the frost blinks off at the one moment it must not.
    /// Holding the display stops the slide happening at all, which is what a
    /// curtain is for: nothing moves, nothing shows.
    ///
    /// Only the curtain holds it, and only with a picture to hold it with: a
    /// held display composes nothing but this window, so an empty one would
    /// leave a black screen. The automatic frost never holds anything — it is
    /// on all day, and a Mac whose desktops are stuck all day is worse than a
    /// frost that blinks.
    private func show(_ window: NSWindow, over id: CGDirectDisplayID, seizing: Bool) {
        window.orderFrontRegardless()
        fade(window, to: 1, over: Self.fadeIn) { [weak self] in
            // Once the frost is all the way up: entering capture blanks the
            // display for an instant, which belongs behind it.
            guard seizing, let self, self.windows[id] === window else { return }
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            if CGDisplayCaptureWithOptions(id, .noFill) == .success {
                self.seized.insert(id)
            } else {
                window.level = .screenSaver
            }
        }
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
    private static func picture(_ image: NSImage, over screen: NSScreen) -> NSView {
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.autoresizingMask = [.width, .height]
        return view
    }
}
