import AppKit
import ApplicationServices

/// Holds the desktop still while the frost is down.
///
/// macOS animates the slide between desktops without drawing any of our
/// windows, so the frost blinks off at the one moment it must not. The slide
/// cannot be covered, so it is stopped instead: while the curtain is down the
/// gestures and keys that change desktop go nowhere. Everything else still
/// works, the frost's own ⇧⌘9 included, and the tap exists only for as long
/// as the frost does.
@MainActor
enum SwipeGuard {
    /// Gesture and swipe, as AppKit numbers them; there are no `CGEventType`
    /// cases for either.
    private static let gestureMask: CGEventMask =
        (1 << NSEvent.EventType.gesture.rawValue) | (1 << NSEvent.EventType.swipe.rawValue)

    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?

    /// Whether macOS lets us read events at all. Without it the frost still
    /// works; the desktop just keeps sliding out from under it.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Asks once, with the system's own prompt.
    static func ask() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func start() {
        guard tap == nil, isAllowed else { return }
        let mask = gestureMask | (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: handle, userInfo: nil)
        else { return }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    static func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    /// Switched off again by a slow callback or by a password field; either
    /// way it has to be switched back on by hand.
    fileprivate static func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

/// Swallows what changes desktop and passes everything else through. A C
/// callback, so it cannot be a method and cannot be on the main actor.
private func handle(proxy: CGEventTapProxy, type: CGEventType,
                    event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { SwipeGuard.reenable() }
        return Unmanaged.passUnretained(event)
    case .keyDown:
        // ⌃← and ⌃→, the keyboard way to the next desktop. Nothing else is
        // touched: ⇧⌘9 has to keep working, or the frost could not be lifted.
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let arrows: Set<Int64> = [123, 124]
        return event.flags.contains(.maskControl) && arrows.contains(key)
            ? nil : Unmanaged.passUnretained(event)
    default:
        // Gesture and swipe: the three-finger slide between desktops.
        return nil
    }
}
