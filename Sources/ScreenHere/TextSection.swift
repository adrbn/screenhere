import SwiftUI

/// The panel's rows for ⇧⌘7 and the clipboard history, in the same row
/// vocabulary as everything else under the map.
struct TextSection: View {
    @ObservedObject var shortcuts: TextShortcuts
    @ObservedObject var clipboard: ClipboardController

    var body: some View {
        VStack(spacing: 1) {
            PanelRow(icon: "text.viewfinder", title: "Copy Text from Screen") {
                ShortcutChip(keys: "⇧⌘7")
                    .opacity(shortcuts.copyTextEnabled ? 1 : 0.45)
                toggle(isOn: shortcuts.copyTextEnabled, set: shortcuts.setCopyTextEnabled)
                    .help("Select part of the screen and copy the text in it, recognised on this Mac. "
                          + "Replaces macOS's Touch Bar screenshot shortcut while on.")
            }
            if shortcuts.copyTextUnavailable {
                warning("macOS or another app is keeping ⇧⌘7")
            }

            PanelRow(icon: "doc.on.clipboard", title: "Clipboard History") {
                ShortcutChip(keys: "⇧⌘8")
                    .opacity(clipboard.isEnabled ? 1 : 0.45)
                toggle(isOn: clipboard.isEnabled) { on in
                    clipboard.setEnabled(on)
                    shortcuts.rebind()
                }
                .help("Keep what you copy, text and images, on this Mac — up to 100 MB of images. "
                      + "Password managers' copies are skipped.")
            }

            if clipboard.isEnabled {
                if shortcuts.historyUnavailable {
                    warning("Another app already uses ⇧⌘8")
                }
                if clipboard.needsPasteAccess {
                    PanelRow(icon: "exclamationmark.triangle", title: "Allow Clipboard Access…",
                             action: clipboard.openPasteAccessSettings)
                        .foregroundStyle(Theme.warning)
                }
                PanelRow(icon: "clock.arrow.circlepath", title: "Show History",
                         trailingText: "\(clipboard.history.items.count)",
                         action: { HistoryPicker.shared.show() })
                PanelRow(icon: "trash", title: "Clear History", action: confirmClear)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .onAppear { clipboard.refreshAccess() }
    }

    private func toggle(isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.brand)
            .labelsHidden()
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .foregroundStyle(Theme.warning)
        .padding(.horizontal, 6)
        .frame(height: 20)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Everything ScreenHere kept will be deleted from this Mac. "
            + "What is on the clipboard right now stays."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { clipboard.clear() }
    }
}
