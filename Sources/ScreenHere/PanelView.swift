import SwiftUI

/// The menu-bar panel. Its centrepiece is a live map of the displays: the one
/// under the pointer is filled, the others are outlined, and a dot tracks the
/// real pointer position. That single picture says what the app does in a way
/// a line of text never did.
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
            Divider().padding(.horizontal, 14)
            map
            Divider().padding(.horizontal, 14)
            rows
            Divider().padding(.horizontal, 14)
            footer
        }
        .frame(width: 272)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("ScreenHere")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn },
                                         set: { model.setTakeover($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                shortcutChip("⇧⌘3")
                Text(PanelStrings.headline(isOn: model.isOn))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.hasPermission {
                Button(action: model.openScreenRecordingSettings) {
                    Label("Screen Recording permission needed",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
            }
            if let problem = PanelStrings.problem(status: model.status,
                                                  permissionGranted: model.hasPermission),
               model.hasPermission {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func shortcutChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
    }

    // MARK: - Display map

    private var map: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayMap(displays: model.displays.map(\.bounds),
                       pointer: model.pointer,
                       activeIndex: model.activeDisplayIndex)
                .frame(height: 96)
                .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(PanelStrings.shortName(model.activeDisplayName))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(model.destination)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text("Launch at Login").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: Binding(get: { model.launchesAtLogin },
                                         set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)

            PanelRow(title: "Restore macOS Shortcuts",
                     systemImage: "arrow.uturn.backward", action: onRestoreShortcuts)
            PanelRow(title: "Hide Menu Bar Icon",
                     systemImage: "eye.slash", action: onHideIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Check for Updates", action: onCheckUpdates)
            Button("GitHub", action: onOpenGitHub)
            Spacer()
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// A borderless row that highlights on hover, so the panel still feels like a menu.
private struct PanelRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The live arrangement, drawn from the same geometry the capture uses.
private struct DisplayMap: View {
    let displays: [CGRect]
    let pointer: CGPoint
    let activeIndex: Int

    var body: some View {
        GeometryReader { geo in
            let fitted = DisplayMapLayout.fit(displays: displays, pointer: pointer,
                                              into: geo.size, padding: 6)
            ZStack(alignment: .topLeading) {
                ForEach(Array(fitted.rects.enumerated()), id: \.offset) { index, r in
                    let isActive = index == activeIndex
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                       : AnyShapeStyle(Color.secondary.opacity(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(isActive ? Color.accentColor
                                                       : Color.secondary.opacity(0.35),
                                              lineWidth: isActive ? 1.6 : 1)
                        )
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                if let p = fitted.pointer {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .shadow(color: .white.opacity(0.9), radius: 1)
                        .offset(x: p.x - 3, y: p.y - 2)
                }
            }
        }
    }
}
