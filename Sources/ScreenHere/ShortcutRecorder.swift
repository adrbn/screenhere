import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The window shortcut, as a field: click it, press the keys you want. Esc
/// cancels, and so does closing the menu.
struct ShortcutRecorder: View {
    @ObservedObject var window: WindowShortcuts
    @StateObject private var typing = ShortcutTyping()

    @State private var hostWindow: NSWindow?

    private var recording: Bool { window.isRecording }

    var body: some View {
        HStack(spacing: 4) {
            if !recording && window.shortcut != .shiftCommand2 {
                Button(action: window.resetShortcut) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to ⇧⌘2")
            }

            Button(action: { recording ? window.endRecording() : typing.begin(on: hostWindow, for: window) }) {
                Text(text)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(typing.problem != nil ? AnyShapeStyle(Theme.warning)
                                     : recording ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 92, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(recording ? AnyShapeStyle(Theme.brand.opacity(0.12))
                                        : AnyShapeStyle(Color.primary.opacity(0.07))))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.brand.opacity(recording ? 0.55 : 0), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Press the new shortcut, or Esc to cancel"
                            : "Click, then press the shortcut you want")
            .accessibilityLabel("Window shortcut")
            .accessibilityValue(recording ? "Recording" : window.shortcut.label())
        }
        .background(WindowReader { hostWindow = $0 })
        .onChange(of: window.isRecording) { isRecording in
            if !isRecording { typing.end() }
        }
    }

    private var text: String {
        guard recording else { return window.shortcut.label() }
        if let problem = typing.problem { return problem }
        return typing.held.isEmpty ? "Type shortcut" : typing.held
    }
}

/// What the recording needs while it lasts: the keys, and the two ways it can
/// end without anyone pressing anything. Kept in an object of its own so
/// whatever ends it can undo it, even once SwiftUI has stopped listening.
@MainActor
final class ShortcutTyping: ObservableObject {
    @Published private(set) var held = ""
    @Published private(set) var problem: String?

    private var monitor: Any?
    private var watchers: [NSObjectProtocol] = []

    func begin(on hostWindow: NSWindow?, for window: WindowShortcuts) {
        end()
        held = ""
        problem = nil
        window.beginRecording()
        hostWindow?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Should the recording end without this object hearing of it, the
            // keys go back to where they were going.
            guard window.isRecording else {
                self?.end()
                return event
            }
            self?.handle(event, for: window)
            return nil
        }
        watch(hostWindow, window)
    }

    /// SwiftUI says nothing when the menu closes, so the window itself does:
    /// it stops being key, and stops being on screen.
    private func watch(_ hostWindow: NSWindow?, _ window: WindowShortcuts) {
        guard let hostWindow else { return }
        let center = NotificationCenter.default
        watchers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification,
                               object: hostWindow, queue: .main) { _ in
                MainActor.assumeIsolated { window.endRecording() }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                               object: hostWindow, queue: .main) { notification in
                let panel = notification.object as? NSWindow
                guard panel?.occlusionState.contains(.visible) != true else { return }
                MainActor.assumeIsolated { window.endRecording() }
            },
        ]
    }

    private func handle(_ event: NSEvent, for window: WindowShortcuts) {
        let modifiers = KeyShortcut.carbonModifiers(from: event.modifierFlags)
        if event.type == .flagsChanged {
            held = KeyShortcut.symbols(for: modifiers)
            problem = nil
            return
        }
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
            window.endRecording()
            return
        }
        problem = window.setShortcut(KeyShortcut(event: event))?.message
    }

    /// However the recording ended, the keys are the app's again.
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        watchers.forEach(NotificationCenter.default.removeObserver)
        watchers = []
        held = ""
        problem = nil
    }
}
