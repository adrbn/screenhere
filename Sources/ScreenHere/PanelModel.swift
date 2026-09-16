import AppKit
import Combine

/// Everything the panel shows, refreshed while it is open.
///
/// The pointer moves continuously, so the map would go stale the moment the
/// panel appeared. Polling is confined to the time the panel is on screen —
/// a menu-bar agent has no business running a timer the rest of the day.
final class PanelModel: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var displayNames: [String] = []
    @Published private(set) var pointer: CGPoint = .zero
    @Published private(set) var activeDisplayIndex: Int = 0     // 0-based
    @Published private(set) var activeDisplayName: String = ""
    @Published private(set) var destination: String = ""
    @Published private(set) var hasPermission: Bool = true
    /// True when we believe we hold ⇧⌘3 but macOS has it enabled too.
    @Published private(set) var systemStillHandlesShortcut: Bool = false
    @Published var isOn: Bool = false
    @Published var launchesAtLogin: Bool = false
    @Published var showsOwnPreview: Bool = false

    private let takeover: TakeoverController
    private var timer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    /// The one model the running app uses. Held outside the `App` struct on
    /// purpose: as a `@StateObject` there, every pointer tick re-evaluated the
    /// scene, rebuilt the menu-bar label, and made AppKit re-snapshot the
    /// status item ten times a second.
    static let shared = PanelModel(takeover: .shared)

    /// The window MenuBarExtra hosts the panel in, reported by the view itself.
    private(set) weak var panelWindow: NSWindow?

    /// Whether the panel is actually on screen. Injectable for tests; the app
    /// asks the panel's own window — never "any window of the app", because
    /// the status item's window is always visible and that guard never fired.
    var isPanelOnScreen: () -> Bool = { false }

    var isPolling: Bool { timer != nil }

    /// Where the live state is sampled from. Injectable so previews and the
    /// documentation shots can pose a fixed arrangement without a second
    /// display plugged in.
    var sampleDisplays: () -> [DisplayInfo] = { CursorDisplay.activeDisplays() }
    var samplePointer: () -> CGPoint = { CursorDisplay.cursorLocation() }

    /// Names for displays that have no matching NSScreen — only used by posed
    /// previews and the documentation shots, empty in the running app.
    var posedNames: [CGDirectDisplayID: String] = [:]

    /// Overrides the permission and takeover state for documentation shots,
    /// which run outside an app bundle and therefore hold neither.
    var posedState: (permission: Bool, isOn: Bool)?

    init(takeover: TakeoverController) {
        self.takeover = takeover
        refresh()
    }

    var status: TakeoverController.Status { takeover.status }

    /// Called by the panel once it knows its window. From then on the window's
    /// occlusion state drives polling: it starts when the panel is ordered in
    /// and stops when it is ordered out, whatever SwiftUI's lifecycle does.
    func attach(window: NSWindow) {
        guard window !== panelWindow else { return }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        panelWindow = window
        isPanelOnScreen = { [weak window] in
            guard let window else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isPanelOnScreen() {
                if !self.isPolling { self.startPolling() }
            } else {
                self.stopPolling()
            }
        }
        if isPanelOnScreen() && !isPolling { startPolling() }
    }

    func startPolling() {
        refreshEnvironment()
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // SwiftUI calls neither onDisappear for MenuBarExtra content nor
            // anything else on close, so the timer checks for itself.
            guard self.isPanelOnScreen() else {
                self.stopPolling()
                return
            }
            self.refresh()
        }
        // .common so the pointer keeps updating while a control is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Cheap sampling, safe to run continuously: two CoreGraphics calls and a
    /// name lookup that only reruns when the display set actually changes.
    func refresh() {
        let displays = sampleDisplays()
        let pointer = samplePointer()

        if displays.map(\.id) != self.displays.map(\.id) {
            self.displays = displays
            displayNames = displays.map { d in
                var name = CursorDisplay.name(of: d.id) ?? posedNames[d.id] ?? ""
                // "Built-in Retina Display" -> "Built-in Retina": the word adds
                // nothing inside a rectangle that is visibly a display.
                if name.hasSuffix(" Display") { name.removeLast(" Display".count) }
                guard name.count > 16 else { return name }
                return String(name.prefix(15)).trimmingCharacters(in: .whitespaces) + "…"
            }
        } else if self.displays != displays {
            self.displays = displays
        }

        // @Published fires on every assignment, equal or not, and each fire
        // re-renders the panel. Only a real change is worth that.
        if self.pointer != pointer { self.pointer = pointer }
        // captureIndex speaks screencapture's language, where displays are
        // numbered from one. The map indexes an array.
        let index = CursorDisplay.captureIndex(
            for: pointer, in: displays, mainDisplayID: CGMainDisplayID()) - 1
        if activeDisplayIndex != index { activeDisplayIndex = index }
        let activeID = displays.indices.contains(index) ? displays[index].id : nil
        // Posed names win when they exist, so a documentation shot or a test is
        // not overruled by whatever real screen happens to sit under the point.
        // The map is empty in the running app, so this changes nothing there.
        let name = activeID.flatMap { posedNames[$0] }
            ?? CursorDisplay.displayName(at: pointer)
            ?? "unknown display"
        if activeDisplayName != name { activeDisplayName = name }
    }

    /// Expensive sampling — an XPC round trip for the login item, a TCC query
    /// for the permission, and a `defaults` subprocess to read the live hotkey
    /// entries. Sampled when the panel opens and after an action changes
    /// something, never on the timer: at 12 Hz this alone cost 20% of a core
    /// and drove the window server to 50%.
    func refreshEnvironment() {
        destination = ScreenshotSettings.current
        hasPermission = posedState?.permission ?? CaptureRunner.hasScreenRecordingPermission
        isOn = posedState?.isOn ?? takeover.isOn
        launchesAtLogin = LoginItem.isEnabled
        showsOwnPreview = PreviewCoordinator.isEnabled
        systemStillHandlesShortcut = posedState == nil
            && takeover.isOn && !takeover.holdsShortcuts
    }

    // MARK: - Actions

    func setTakeover(_ on: Bool) {
        if on {
            if !CaptureRunner.hasScreenRecordingPermission {
                CaptureRunner.requestScreenRecordingPermission()
            }
            takeover.enable()
        } else {
            takeover.disable()
        }
        refreshEnvironment()
        refresh()
    }

    /// Turning this on takes over macOS's capture preview so ours can appear on
    /// the display that was actually captured; turning it off gives the user's
    /// setting straight back.
    @MainActor
    func setOwnPreview(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: PreviewPrefs.enabledKey)
        if on {
            SystemThumbnail.suppress()
            CaptureWatcher.shared.start()
        } else {
            SystemThumbnail.restore()
            CaptureWatcher.shared.stop()
        }
        refreshEnvironment()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshEnvironment()
    }

    func openScreenRecordingSettings() {
        CaptureRunner.requestScreenRecordingPermission()
        // macOS 13+ serves this pane from an ExtensionKit extension; the old
        // com.apple.preference.security identifier makes System Settings quit.
        if let url = URL(string: "x-apple.systempreferences:"
            + "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
