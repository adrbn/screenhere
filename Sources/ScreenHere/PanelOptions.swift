import SwiftUI

/// The settings of the features that are on, so the panel only grows with
/// what is in use.
struct PanelOptions: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var window: WindowShortcuts
    @ObservedObject var clipboard: ClipboardController
    @ObservedObject var links: LinkPreviewController

    var body: some View {
        VStack(spacing: 1) {
            if clipboard.isEnabled && clipboard.needsPasteAccess {
                PanelRow(icon: "exclamationmark.triangle", title: "Allow clipboard access…",
                         action: clipboard.openPasteAccessSettings)
                    .foregroundStyle(Theme.warning)
            }

            if window.isEnabled {
                PanelRow(icon: "macwindow", title: "Window shortcut") {
                    ShortcutRecorder(window: window)
                }
            }

            PanelRow(icon: "photo.on.rectangle.angled", title: "Preview on captured screen") {
                toggle(isOn: model.showsOwnPreview, set: { model.setOwnPreview($0) })
                    .help("Show the capture preview on the screen it came from, "
                          + "instead of wherever macOS puts it")
            }
            PanelRow(icon: "power", title: "Launch at login") {
                toggle(isOn: model.launchesAtLogin, set: model.setLaunchAtLogin)
            }

            if clipboard.isEnabled {
                PanelRow(icon: "link", title: "Link previews", beta: true) {
                    toggle(isOn: links.isEnabled, set: links.setEnabled)
                        .help("Show the title and icon of copied links in the list. ScreenHere visits a link "
                              + "when the list shows it, without cookies, and never one that looks private "
                              + "or single-use. The site sees the visit, as it would if you opened the link.")
                }
                PanelRow(icon: "clock.arrow.circlepath", title: "Show history",
                         trailingText: "\(clipboard.history.items.count)",
                         action: { HistoryPicker.shared.show() })
                PanelRow(icon: "trash", title: "Clear history", action: confirmClear)
            }
        }
        .onAppear { clipboard.refreshAccess() }
    }

    private func toggle(isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.brand)
            .labelsHidden()
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
