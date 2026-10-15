import SwiftUI

/// A room of settings, named after what it changes. The panel shows one room
/// at a time, so its height no longer grows with everything that is switched
/// on — and a setting gets space for the sentence that explains it.
enum PanelPage: String, CaseIterable, Identifiable {
    case captures = "Captures"
    case privacy = "Privacy screen"
    case clipboard = "Clipboard"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .captures: "camera.viewfinder"
        case .privacy: "eye.slash"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

/// The settings of the features that are on: the rooms to go to, or the one
/// that is open.
struct PanelOptions: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var window: WindowShortcuts
    @ObservedObject var clipboard: ClipboardController
    @ObservedObject var links: LinkPreviewController
    @ObservedObject var sync: SyncController
    @ObservedObject var blur: ScreenBlur = .shared

    /// The room on show, or none for the list of rooms.
    var page: PanelPage?
    var open: (PanelPage) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 1) {
            switch page {
            case .none: doors
            case .captures: captures
            case .privacy: privacy
            case .clipboard: clipboardSettings
            }
        }
        .onAppear { clipboard.refreshAccess() }
    }

    /// The way in to each room, and anything that cannot wait behind a door.
    @ViewBuilder private var doors: some View {
        if (clipboard.isEnabled || sync.isEnabled) && clipboard.needsPasteAccess {
            PanelRow(icon: "exclamationmark.triangle", title: "Allow clipboard access…",
                     action: clipboard.openPasteAccessSettings)
                .foregroundStyle(Theme.warning)
        }
        ForEach(PanelPage.allCases) { page in
            // A frosted screen is the only one whose room is empty when the
            // feature is off.
            if page != .privacy || blur.isEnabled {
                PanelRow(icon: page.icon, title: page.rawValue, action: { open(page) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var captures: some View {
        if window.isEnabled {
            PanelRow(icon: "macwindow", title: "Window shortcut") {
                ShortcutRecorder(window: window)
            }
        }
        PanelRow(icon: "photo.on.rectangle.angled", title: "Preview on captured screen") {
            toggle(isOn: model.showsOwnPreview, set: { model.setOwnPreview($0) })
        }
        note("Click it to find the file, drag it into another app, or flick it right to dismiss.")
    }

    @ViewBuilder private var privacy: some View {
        PanelRow(icon: "rectangle.on.rectangle.slash", title: "Blur the screens you're not on") {
            toggle(isOn: blur.blursOthers, set: blur.setBlursOthers)
        }
        note("A display frosts a second after the pointer leaves it, and clears when it returns.")
        PanelRow(icon: "hand.raised", title: "Freeze the desktop", beta: true) {
            toggle(isOn: blur.holdsDisplay, set: blur.setHoldsDisplay)
        }
        note("Stops macOS sliding to another desktop mid-swipe. Flashes once as the frost falls.")
    }

    @ViewBuilder private var clipboardSettings: some View {
        if clipboard.isEnabled {
            PanelRow(icon: "link", title: "Link previews", beta: true) {
                toggle(isOn: links.isEnabled, set: links.setEnabled)
            }
            note("The link is opened without cookies, never a private one. The site sees the visit.")
        }
        sharedClipboard
    }

    /// What a setting does, in the room's own space — which is the point of
    /// having rooms: this used to have to fit in a tooltip.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
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
                if let address = sync.ownAddress {
                    // For the networks where the other device never finds
                    // this one: it can be told where to look.
                    PanelRow(icon: "globe", title: "This Mac is at") {
                        Text(address)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                    .help("If this Mac does not show up on the other device, type this address there.")
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
}
