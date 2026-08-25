import AppKit
import Carbon.HIToolbox

/// One key combination ScreenHere takes over, described in both encodings it
/// needs: Carbon's for `RegisterEventHotKey`, Cocoa's for cross-checking
/// against the symbolic-hotkey entry we disable.
struct HotkeyCombo: Equatable {
    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32

    /// ⇧⌘3 — mirrors symbolic hotkey 28.
    static let screenshotToDestination = HotkeyCombo(
        id: 1, keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(shiftKey | cmdKey))

    /// ⌃⇧⌘3 — mirrors symbolic hotkey 29.
    static let screenshotToClipboard = HotkeyCombo(
        id: 2, keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(shiftKey | cmdKey | controlKey))

    /// The same modifiers in the Cocoa bit layout macOS stores in
    /// `AppleSymbolicHotKeys ▸ value ▸ parameters[2]`.
    var cocoaModifierMask: Int {
        var mask = 0
        if carbonModifiers & UInt32(shiftKey) != 0 { mask |= Int(NSEvent.ModifierFlags.shift.rawValue) }
        if carbonModifiers & UInt32(controlKey) != 0 { mask |= Int(NSEvent.ModifierFlags.control.rawValue) }
        if carbonModifiers & UInt32(optionKey) != 0 { mask |= Int(NSEvent.ModifierFlags.option.rawValue) }
        if carbonModifiers & UInt32(cmdKey) != 0 { mask |= Int(NSEvent.ModifierFlags.command.rawValue) }
        return mask
    }
}

/// Registering global key combinations, behind a protocol so the controller
/// can be tested without touching the real event system.
protocol HotkeyBinding: AnyObject {
    /// Registers every combo. Returns false if any registration failed, in
    /// which case nothing stays registered.
    func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool
    func unbindAll()
}

/// Carbon `RegisterEventHotKey`. Chosen over `NSEvent` monitors because those
/// observe without consuming, and over a `CGEventTap` because taps need
/// Accessibility permission and get disarmed by the input watchdog.
final class HotkeyRegistrar: HotkeyBinding {
    fileprivate static let signature: OSType = 0x53_43_52_48   // 'SCRH'

    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var onFire: ((UInt32) -> Void)?

    func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool {
        unbindAll()
        self.onFire = onFire
        installHandlerIfNeeded()

        for combo in combos {
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: combo.id)
            let status = RegisterEventHotKey(
                combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0,
                &reference)
            guard status == noErr, let reference else {
                unbindAll()          // all or nothing: never half-registered
                return false
            }
            references.append(reference)
        }
        return true
    }

    func unbindAll() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        onFire?(id)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, hotKeyID.signature == HotkeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                registrar.fire(hotKeyID.id)
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unbindAll()
        if let handler { RemoveEventHandler(handler) }
    }
}
