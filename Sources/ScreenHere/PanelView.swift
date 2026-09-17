import SwiftUI

/// The menu-bar panel: the live map of the displays, one tile per shortcut, the
/// options of whatever is switched on, and a footer.
///
/// The map stays the centrepiece: the display under the pointer is filled in
/// the brand colour and a pointer tracks the real cursor, which says what the
/// app does better than a line of text. The tiles follow Control Center, where
/// the whole tile switches its feature, so four features read at a glance.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var updater = UpdaterController.shared

    var onRestoreShortcuts: () -> Void
    var onHideIcon: () -> Void
    var onCheckUpdates: () -> Void
    var onOpenGitHub: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHero(model: model)
                .padding(10)

            SectionTitle(text: "Shortcuts")
            PanelTiles(model: model, window: .shared, text: .shared, clipboard: .shared)
                .padding(.horizontal, 10)

            SectionTitle(text: "Options")
                .padding(.top, 10)
            PanelOptions(model: model, window: .shared, clipboard: .shared, links: .shared)
                .padding(.horizontal, 6)

            Divider()
                .padding(.horizontal, 12)
                .padding(.top, 6)
            footer
        }
        .frame(width: 320)
        .background(WindowReader { model.attach(window: $0) })
    }

    private var footer: some View {
        HStack(spacing: 6) {
            UpdateButton(updater: updater, action: onCheckUpdates)
            Spacer(minLength: 8)
            Menu {
                Button("View on GitHub", action: onOpenGitHub)
                Divider()
                Button("Restore macOS Shortcuts", action: onRestoreShortcuts)
                Button("Hide Menu Bar Icon", action: onHideIcon)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(0.06)))
            .help("More")
            RoundButton(icon: "power", help: "Quit ScreenHere", action: onQuit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

// MARK: - Pieces

enum Theme {
    /// The app's violet, the same one the icon is drawn in — so the panel reads
    /// as ScreenHere rather than as a generic system sheet.
    static let brand = Color(red: 0.49, green: 0.31, blue: 0.94)
    static let warning = Color(red: 0.85, green: 0.45, blue: 0.05)
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
    }
}

struct ShortcutChip: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09)))
    }
}

struct BetaChip: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.brand)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.brand.opacity(0.14)))
    }
}

/// Check for Updates, which turns into a highlighted Update button once
/// Sparkle has found one.
private struct UpdateButton: View {
    @ObservedObject var updater: UpdaterController
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let available = updater.availableVersion
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: available == nil ? "arrow.down.circle" : "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(available == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.brand))
                Text(available.map { "Update to \($0)" } ?? "Check for Updates")
                    .font(.system(size: 12, weight: available == nil ? .regular : .medium))
                // "0.0.0" is the unbundled fallback; showing it would be a lie.
                if available == nil, UpdaterController.currentVersion != "0.0.0" {
                    Text(UpdaterController.currentVersion)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(available != nil ? Theme.brand.opacity(0.13)
                                       : Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RoundButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One row of the options: fixed icon column, title, optional trailing control
/// or hint. Rows with an action highlight on hover; rows that only host a
/// control do not, because there is nothing to click in the row itself.
struct PanelRow<Trailing: View>: View {
    let icon: String
    let title: String
    var beta = false
    var trailingText: String?
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        let content = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12))
            if beta { BetaChip() }
            Spacer(minLength: 8)
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            trailing()
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering && action != nil
                  ? AnyShapeStyle(Color.primary.opacity(0.07))
                  : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            content
        }
    }
}

extension PanelRow where Trailing == EmptyView {
    init(icon: String, title: String, trailingText: String? = nil,
         action: @escaping () -> Void) {
        self.init(icon: icon, title: title, beta: false, trailingText: trailingText,
                  action: action, trailing: { EmptyView() })
    }
}

extension PanelRow {
    init(icon: String, title: String, beta: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(icon: icon, title: title, beta: beta, trailingText: nil,
                  action: nil, trailing: trailing)
    }
}
