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
    @Published var isOn: Bool = false
    @Published var launchesAtLogin: Bool = false

    private let takeover: TakeoverController
    private var timer: Timer?

    /// Where the live state is sampled from. Injectable so previews and the
    /// documentation shots can pose a fixed arrangement without a second
    /// display plugged in.
    var sampleDisplays: () -> [DisplayInfo] = { CursorDisplay.activeDisplays() }
    var samplePointer: () -> CGPoint = { CursorDisplay.cursorLocation() }

    init(takeover: TakeoverController) {
        self.takeover = takeover
        refresh()
    }

    var status: TakeoverController.Status { takeover.status }

    func startPolling() {
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common so the pointer keeps updating while a control is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let displays = sampleDisplays()
        let pointer = samplePointer()
        self.displays = displays
        // Short enough to fit inside a map rectangle: "Built-in Retina Display"
        // becomes "Built-in", "MSI MD271UL" stays whole.
        displayNames = displays.map { d in
            var name = CursorDisplay.name(of: d.id) ?? posedNames[d.id] ?? ""
            // "Built-in Retina Display" -> "Built-in Retina": the word adds
            // nothing inside a rectangle that is visibly a display.
            if name.hasSuffix(" Display") { name.removeLast(" Display".count) }
            guard name.count > 16 else { return name }
            return String(name.prefix(15)).trimmingCharacters(in: .whitespaces) + "…"
        }
        self.pointer = pointer
        activeDisplayIndex = CursorDisplay.captureIndex(
            for: pointer, in: displays, mainDisplayID: CGMainDisplayID()) - 1
        let activeID = displays.indices.contains(activeDisplayIndex)
            ? displays[activeDisplayIndex].id : nil
        activeDisplayName = CursorDisplay.displayName(at: pointer)
            ?? activeID.flatMap { posedNames[$0] }
            ?? "unknown display"
        destination = ScreenshotSettings.current
        hasPermission = CaptureRunner.hasScreenRecordingPermission
        isOn = takeover.isOn
        launchesAtLogin = LoginItem.isEnabled
    }

    /// Names for displays that have no matching NSScreen — only used by posed
    /// previews, empty in the running app.
    var posedNames: [CGDirectDisplayID: String] = [:]

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
        refresh()
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
        refresh()
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
