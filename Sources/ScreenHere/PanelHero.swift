import SwiftUI

/// The top of the panel: which display ⇧⌘3 takes right now, where the capture
/// goes, and the live map of the displays.
struct PanelHero: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label {
                    Text(PanelStrings.shortName(model.activeDisplayName))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 9))
                    Text(model.destination)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help("Where captures go, as set in the Screenshot app")
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
            }

            DisplayMap(displays: model.displays.map(\.bounds),
                       names: model.displayNames,
                       pointer: model.pointer,
                       activeIndex: model.activeDisplayIndex)
                .frame(height: 88)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.14), value: model.activeDisplayIndex)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.brand.opacity(scheme == .dark ? 0.13 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.brand.opacity(0.14)))
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
                        .frame(width: 8.7, height: 15)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: p.x - 1, y: p.y - 1)
                }
            }
        }
    }

    private func screen(_ r: CGRect, isActive: Bool, name: String) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isActive ? Theme.brand.opacity(0.20) : Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isActive ? Theme.brand : Color.primary.opacity(0.20),
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
                        .padding(.horizontal, 5)
                        .padding(.bottom, 4)
                        .frame(maxWidth: r.width, alignment: .leading)
                }
            }
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }
}

/// The same outline as the menu-bar icon.
private struct Pointer: Shape {
    func path(in rect: CGRect) -> Path {
        let size = MenuBarIcon.pointerSize
        var path = Path()
        path.addLines(MenuBarIcon.pointerOutline.map {
            CGPoint(x: rect.minX + $0.x / size.width * rect.width,
                    y: rect.minY + $0.y / size.height * rect.height)
        })
        path.closeSubpath()
        return path
    }
}
