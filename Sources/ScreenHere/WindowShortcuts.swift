import Foundation

extension HotkeyCombo {
    static let windowToDestinationID: UInt32 = 5
    static let windowToClipboardID: UInt32 = 6
}

enum WindowPrefs {
    static let enabledKey = "WindowCaptureEnabled"
    static let shortcutKey = "WindowCaptureShortcut"
}

/// Capturing the window under the pointer, a beta. Off until turned on, then
/// on ⇧⌘2 or the shortcut the user records.
final class WindowShortcuts: ObservableObject {
    static let shared = WindowShortcuts()

    @Published private(set) var isEnabled = false
    @Published private(set) var shortcut: KeyShortcut = .shiftCommand2
    /// The shortcut is registered by another app.
    @Published private(set) var shortcutUnavailable = false
    /// A new shortcut is being typed. The recorder follows this rather than a
    /// state of its own, so whatever ends the recording ends it everywhere.
    @Published private(set) var isRecording = false

    private let binding: HotkeyBinding
    private let defaults: UserDefaults
    private let capture: (CaptureDestination) -> Void

    init(binding: HotkeyBinding = HotkeyRegistrar(signature: HotkeyRegistrar.windowSignature),
         defaults: UserDefaults = .standard,
         capture: @escaping (CaptureDestination) -> Void = { WindowCapture.run(destination: $0) }) {
        self.binding = binding
        self.defaults = defaults
        self.capture = capture
    }

    func activate() {
        isEnabled = defaults.bool(forKey: WindowPrefs.enabledKey)
        shortcut = storedShortcut() ?? .shiftCommand2
        rebind()
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: WindowPrefs.enabledKey)
        isEnabled = on
        rebind()
    }

    /// Saves and registers `shortcut`, unless the rules refuse it. A shortcut
    /// that goes through ends the recording.
    @discardableResult
    func setShortcut(_ shortcut: KeyShortcut) -> KeyShortcut.Problem? {
        if let problem = shortcut.problem { return problem }
        defaults.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.carbonModifiers)],
                     forKey: WindowPrefs.shortcutKey)
        self.shortcut = shortcut
        isRecording = false
        rebind()
        return nil
    }

    func resetShortcut() {
        defaults.removeObject(forKey: WindowPrefs.shortcutKey)
        shortcut = .shiftCommand2
        rebind()
    }

    /// The shortcut stays registered while a new one is typed: the recorder
    /// only ever adds state that something else can clear, never takes any
    /// away, so a menu that closes mid-recording leaves nothing switched off.
    func beginRecording() {
        isRecording = true
    }

    func endRecording() {
        isRecording = false
    }

    /// Documentation shots only: show a state without registering or saving
    /// anything.
    func pose(enabled: Bool) {
        isEnabled = enabled
    }

    private func storedShortcut() -> KeyShortcut? {
        guard let stored = defaults.dictionary(forKey: WindowPrefs.shortcutKey),
              let keyCode = (stored["keyCode"] as? Int).flatMap(UInt32.init(exactly:)),
              let modifiers = (stored["modifiers"] as? Int).flatMap(UInt32.init(exactly:))
        else { return nil }
        let shortcut = KeyShortcut(keyCode: keyCode, carbonModifiers: modifiers)
        return shortcut.problem == nil ? shortcut : nil
    }

    private func rebind() {
        binding.unbindAll()
        guard isEnabled else {
            shortcutUnavailable = false
            return
        }
        shortcutUnavailable = !binding.bind(shortcut.combos) { [weak self] id in
            guard let self else { return }
            // Pressing the shortcut it already has, while typing a new one:
            // that is the answer, so keep it and stop recording.
            guard !isRecording else { return endRecording() }
            capture(id == HotkeyCombo.windowToClipboardID ? .clipboard : .userSettings)
        }
    }
}
