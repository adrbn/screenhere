import SwiftUI

/// One tile per shortcut. The whole tile switches its feature on and off.
struct PanelTiles: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var window: WindowShortcuts
    @ObservedObject var text: TextShortcuts
    @ObservedObject var clipboard: ClipboardController

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                  spacing: 8) {
            FeatureTile(icon: "display", title: "Screen", detail: .keys("⇧⌘3"),
                        isOn: model.isOn,
                        help: model.isOn ? "Give ⇧⌘3 back to macOS"
                                         : "Capture the screen under the pointer with ⇧⌘3") {
                model.setTakeover(!model.isOn)
            }
            FeatureTile(icon: "macwindow", title: "Window", beta: true, detail: windowDetail,
                        isOn: window.isEnabled,
                        help: "Capture only the window under the pointer. "
                            + "Pick the shortcut in the options below.") {
                window.setEnabled(!window.isEnabled)
            }
            FeatureTile(icon: "text.viewfinder", title: "Text",
                        detail: text.copyTextUnavailable ? .warning("Shortcut in use") : .keys("⇧⌘7"),
                        isOn: text.copyTextEnabled,
                        help: "Select part of the screen and copy the text in it, recognised on this Mac. "
                            + "Replaces macOS's Touch Bar screenshot shortcut while on.") {
                text.setCopyTextEnabled(!text.copyTextEnabled)
            }
            FeatureTile(icon: "doc.on.clipboard", title: "History",
                        detail: clipboard.isEnabled && text.historyUnavailable
                            ? .warning("Shortcut in use") : .keys("⇧⌘8"),
                        isOn: clipboard.isEnabled,
                        help: "Keep what you copy, text and images, on this Mac, up to 100 MB of images. "
                            + "Password managers' copies are skipped.") {
                clipboard.setEnabled(!clipboard.isEnabled)
                text.rebind()
            }
        }
    }

    private var windowDetail: TileDetail {
        if window.isEnabled && window.shortcutUnavailable { return .warning("Shortcut in use") }
        return .keys(window.shortcut.label())
    }
}

enum TileDetail: Equatable {
    case keys(String)
    case warning(String)
}

private struct FeatureTile: View {
    let icon: String
    let title: String
    var beta = false
    let detail: TileDetail
    let isOn: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.09)))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if beta { BetaChip() }
                    }
                    switch detail {
                    case .keys(let keys):
                        Text(keys)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    case .warning(let warning):
                        Text(warning)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.warning)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.085 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
