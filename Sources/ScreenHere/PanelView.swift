import SwiftUI

/// The menu-bar panel.
///
/// Its centrepiece is a live map of the displays: the one under the pointer is
/// filled in the brand colour, the others outlined, and a pointer tracks the
/// real cursor. That single picture says what the app does in a way a line of
/// text never did.
///
/// Everything below the map is one vocabulary — a 24pt row with a fixed icon
/// column, a title, and a trailing control or hint. Quit and Check for Updates
/// are rows too, not loose links in a footer.
struct PanelView: View {
    @ObservedObject var model: PanelModel

    var onRestoreShortcuts: () -> Void
    var onHideIcon: () -> Void
    var onCheckUpdates: () -> Void
    var onOpenGitHub: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            separator
            map
            separator
            controls
            separator
            about
        }
        .frame(width: 300)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var separator: some View {
        Divider().padding(.horizontal, 14)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("ScreenHere")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { model.isOn },
                                         set: { model.setTakeover($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.brand)
                    .labelsHidden()
                    .help(model.isOn ? "Give ⇧⌘3 back to macOS" : "Take ⇧⌘3 over")
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ShortcutChip(keys: "⇧⌘3")
                Text(PanelStrings.headline(isOn: model.isOn))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem = PanelStrings.problem(
                status: model.status,
                permissionGranted: model.hasPermission,
                systemStillHandlesShortcut: model.systemStillHandlesShortcut) {
                Button(action: model.openScreenRecordingSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(problem)
                            .font(.system(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
                // Only the permission warning is actionable; the rest is status.
                .disabled(model.hasPermission)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
    }

    // MARK: - Display map

    private var map: some View {
        VStack(alignment: .leading, spacing: 9) {
            DisplayMap(displays: model.displays.map(\.bounds),
                       names: model.displayNames,
                       pointer: model.pointer,
                       activeIndex: model.activeDisplayIndex)
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.14), value: model.activeDisplayIndex)

            HStack(spacing: 0) {
                Label {
                    Text(PanelStrings.shortName(model.activeDisplayName))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.brand)
                }
                Spacer(minLength: 10)
                Label {
                    Text(model.destination)
                        .font(.system(size: 11))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Rows

    private var controls: some View {
        VStack(spacing: 1) {
            PanelRow(icon: "power", title: "Launch at Login") {
                Toggle("", isOn: Binding(get: { model.launchesAtLogin },
                                         set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.brand)
                    .labelsHidden()
            }
            PanelRow(icon: "arrow.uturn.backward", title: "Restore macOS Shortcuts",
                     action: onRestoreShortcuts)
            PanelRow(icon: "eye.slash", title: "Hide Menu Bar Icon", action: onHideIcon)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var about: some View {
        VStack(spacing: 1) {
            PanelRow(icon: "arrow.down.circle", title: "Check for Updates",
                     // "0.0.0" is the unbundled fallback; showing it would be a
                     // lie, and there is nothing useful to put in its place.
                     trailingText: UpdateChecker.currentVersion == "0.0.0"
                        ? nil : UpdateChecker.currentVersion,
                     action: onCheckUpdates)
            PanelRow(icon: "chevron.left.forwardslash.chevron.right", title: "View on GitHub",
                     action: onOpenGitHub)
            PanelRow(icon: "xmark.circle", title: "Quit ScreenHere",
                     trailingText: "⌘Q", action: onQuit)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }
}

// MARK: - Pieces

private enum Theme {
    /// The app's violet, the same one the icon is drawn in — so the panel reads
    /// as ScreenHere rather than as a generic system sheet.
    static let brand = Color(red: 0.49, green: 0.31, blue: 0.94)
    static let warning = Color(red: 0.85, green: 0.45, blue: 0.05)
}

private struct ShortcutChip: View {
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

/// One row of the panel: fixed icon column, title, optional trailing control or
/// hint. Rows with an action highlight on hover; rows that only host a control
/// do not, because there is nothing to click in the row itself.
private struct PanelRow<Trailing: View>: View {
    let icon: String
    let title: String
    var trailingText: String?
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        let content = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 15, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12))
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
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
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
        self.init(icon: icon, title: title, trailingText: trailingText,
                  action: action, trailing: { EmptyView() })
    }
}

extension PanelRow {
    init(icon: String, title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(icon: icon, title: title, trailingText: nil,
                  action: nil, trailing: trailing)
    }
}

/// The live arrangement, drawn from the same geometry the capture uses.
private struct DisplayMap: View {
    let displays: [CGRect]
    let names: [String]
    let pointer: CGPoint
    let activeIndex: Int

    var body: some View {
        GeometryReader { geo in
            let fitted = DisplayMapLayout.fit(displays: displays, pointer: pointer,
                                              into: geo.size, padding: 4)
            ZStack(alignment: .topLeading) {
                ForEach(Array(fitted.rects.enumerated()), id: \.offset) { index, r in
                    screen(r, isActive: index == activeIndex,
                           name: index < names.count ? names[index] : "")
                }
                if let p = fitted.pointer {
                    Pointer()
                        .fill(Color.primary)
                        .overlay(Pointer().stroke(Color(nsColor: .textBackgroundColor),
                                                  lineWidth: 1.2))
                        .frame(width: 11, height: 14)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: p.x - 1, y: p.y - 1)
                }
            }
        }
    }

    private func screen(_ r: CGRect, isActive: Bool, name: String) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isActive ? Theme.brand.opacity(0.16) : Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isActive ? Theme.brand : Color.primary.opacity(0.22),
                                  lineWidth: isActive ? 1.5 : 1)
            )
            .overlay(alignment: .bottomLeading) {
                // Only label a display that has room for it; a clipped name is
                // worse than none.
                if r.width >= 62, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 8.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? AnyShapeStyle(Theme.brand)
                                                  : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 3)
                        .frame(maxWidth: r.width, alignment: .leading)
                }
            }
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }
}

/// The same silhouette the app icon uses, on a 100-unit square.
private struct Pointer: Shape {
    func path(in rect: CGRect) -> Path {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 100 * rect.width,
                    y: rect.minY + (100 - y) / 100 * rect.height)
        }
        var p = Path()
        p.move(to: P(0, 100)); p.addLine(to: P(0, 22))
        p.addLine(to: P(24, 46)); p.addLine(to: P(40, 15))
        p.addLine(to: P(58, 24)); p.addLine(to: P(42, 54))
        p.addLine(to: P(76, 58)); p.closeSubpath()
        return p
    }
}
