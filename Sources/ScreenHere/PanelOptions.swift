import SwiftUI

/// The settings of the features that are on, so the panel only grows with
/// what is in use.
struct PanelOptions: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var window: WindowShortcuts
    @ObservedObject var clipboard: ClipboardController
    @ObservedObject var links: LinkPreviewController
    @ObservedObject var sync: SyncController

    var body: some View {
        VStack(spacing: 1) {
            if (clipboard.isEnabled || sync.isEnabled) && clipboard.needsPasteAccess {
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

            sharedClipboard

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

    /// The clipboard shared with one other device, and the few steps that
    /// introduce the two: ask on both, pick the device, check the code.
    @ViewBuilder private var sharedClipboard: some View {
        PanelRow(icon: "arrow.left.arrow.right", title: "Shared clipboard", beta: true) {
            toggle(isOn: sync.isEnabled, set: sync.setEnabled)
                .help("Share what you copy — text and pictures — with a Mac or PC on the same network that also "
                      + "runs ScreenHere. The two talk to each other directly and encrypted; nothing goes through "
                      + "a server, and copies that password managers mark as concealed are never sent.")
        }
        if sync.isEnabled {
            if let offer = sync.pending {
                // Asked in place: an alert would close the menu, and the
                // question with it.
                PanelRow(icon: "lock", title: "Same code on \(PanelStrings.shortName(offer.name, max: 20))?") { EmptyView() }
                HStack(spacing: 6) {
                    Text(SyncProtocol.spaced(offer.code))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.brand)
                    Spacer(minLength: 8)
                    if offer.confirmed {
                        Text("Waiting for \(PanelStrings.shortName(offer.name, max: 18))…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Cancel", action: sync.decline)
                            .controlSize(.small)
                        Button("Connect", action: sync.confirm)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.brand)
                    }
                }
                .padding(.leading, 30)
                .padding(.trailing, 6)
                .frame(height: 30)
            } else if sync.isPairing {
                PanelRow(icon: "magnifyingglass",
                         title: sync.nearby.isEmpty ? "Looking for devices…" : "Choose the device") {
                    Button("Cancel", action: sync.endPairing)
                        .controlSize(.small)
                }
                if sync.nearby.isEmpty {
                    Text("Click Connect a device in ScreenHere on the other one too.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .padding(.bottom, 5)
                }
                ForEach(sync.nearby) { device in
                    PanelRow(icon: "desktopcomputer", title: PanelStrings.shortName(device.name, max: 30),
                             action: { sync.pair(with: device) })
                }
            } else if let peer = sync.peer {
                PanelRow(icon: "desktopcomputer", title: PanelStrings.shortName(peer.name, max: 18)) {
                    HStack(spacing: 6) {
                        Text(sync.isConnected ? "Connected" : "Not in reach")
                            .font(.system(size: 11))
                            .foregroundStyle(sync.isConnected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                        Button("Forget", action: sync.forget)
                            .controlSize(.small)
                            .help("Stop sharing with this device. It would have to be connected again.")
                    }
                }
            } else {
                PanelRow(icon: "link", title: "Connect a device…", action: sync.beginPairing)
            }
        }
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
