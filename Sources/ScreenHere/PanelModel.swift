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

    /// Where the live state is sampled from. Injectable so previews and the
    /// documentation shots can pose a fixed arrangement without a second
    /// display plugged in.
    var sampleDisplays: () -> [DisplayInfo] = { CursorDisplay.activeDisplays() }
    var samplePointer: () -> CGPoint = { CursorDisplay.cursorLocation() }

    /// Names for displays that have no matching NSScreen — only used by posed
    /// previews and the documentation shots, empty in the running app.
    var posedNames: [CGDirectDisplayID: String] = [:]

    init(takeover: TakeoverController) {
        self.takeover = takeover
        refresh()
    }

    var status: TakeoverController.Status { takeover.status }

    func startPolling() {
        refreshEnvironment()
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // SwiftUI does not call onDisappear for MenuBarExtra content, so the
            // timer outlived every close and polled forever. An agent with no
            // visible window has no panel on screen and nothing to refresh.
            guard NSApp.windows.contains(where: \.isVisible) else {
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

        self.pointer = pointer
        activeDisplayIndex = CursorDisplay.captureIndex(
            for: pointer, in: displays, mainDisplayID: CGMainDisplayID())
        let activeID = displays.indices.contains(activeDisplayIndex)
            ? displays[activeDisplayIndex].id : nil
        activeDisplayName = CursorDisplay.displayName(at: pointer)
            ?? activeID.flatMap { posedNames[$0] }
            ?? "unknown display"
    }

    /// Expensive sampling — an XPC round trip for the login item, a TCC query
    /// for the permission, and a `defaults` subprocess to read the live hotkey
    /// entries. Sampled when the panel opens and after an action changes
    /// something, never on the timer: at 12 Hz this alone cost 20% of a core
    /// and drove the window server to 50%.
    func refreshEnvironment() {
        destination = ScreenshotSettings.current
        hasPermission = CaptureRunner.hasScreenRecordingPermission
        isOn = takeover.isOn
        launchesAtLogin = LoginItem.isEnabled
        showsOwnPreview = PreviewCoordinator.isEnabled
        systemStillHandlesShortcut = takeover.isOn && !takeover.holdsShortcuts
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
    func setOwnPreview(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: PreviewPrefs.enabledKey)
        if on { SystemThumbnail.suppress() } else { SystemThumbnail.restore() }
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
