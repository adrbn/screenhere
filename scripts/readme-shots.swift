import AppKit
import SwiftUI

// The README pictures, drawn from the app's own views with posed data. Reads
// nothing from the real clipboard and captures nothing from the screen.
// Run through scripts/readme-shots.sh.

/// Controls draw in their active colours only in an active app's key window.
final class RenderApp: NSApplication {
    override var isActive: Bool { true }
}

final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

let brand = Color(red: 0.49, green: 0.31, blue: 0.94)

// MARK: - Stage 1: the real UI, through AppKit

@MainActor
func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, dark: Bool, background: NSColor,
                       key: Bool = true) -> NSImage {
    let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    hosting.appearance = appearance
    let fitted = hosting.fittingSize
    let size = NSSize(width: width, height: height ?? fitted.height)
    let window = (key ? KeyWindow.self : NSWindow.self).init(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.isOpaque = false
    window.backgroundColor = background
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    if key {
        // Far off every display, so nothing shows while it is up.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    window.orderOut(nil)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

// MARK: - Stage 2: the scene around it, through SwiftUI

@MainActor
func export<V: View>(_ view: V, dark: Bool, to path: String) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = 2
    guard let cg = renderer.cgImage else { fatalError("render failed: \(path)") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(cg.width)×\(cg.height)")
}

struct ShotWallpaper: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark
                           ? [Color(red: 0.09, green: 0.07, blue: 0.20), Color(red: 0.16, green: 0.10, blue: 0.32)]
                           : [Color(red: 0.86, green: 0.83, blue: 0.99), Color(red: 0.72, green: 0.80, blue: 0.99)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                Circle().fill(brand.opacity(dark ? 0.55 : 0.40))
                    .frame(width: geo.size.width * 0.8)
                    .blur(radius: 80)
                    .position(x: geo.size.width * 0.15, y: geo.size.height * 0.9)
                Circle().fill(Color(red: 0.25, green: 0.65, blue: 1).opacity(dark ? 0.30 : 0.35))
                    .frame(width: geo.size.width * 0.6)
                    .blur(radius: 80)
                    .position(x: geo.size.width * 0.95, y: geo.size.height * 0.1)
            }
        }
    }
}

/// A rounded scene with a hairline edge, so it holds its shape on white and
/// on GitHub's dark page alike.
struct Stage<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let dark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ZStack { content }
            .frame(width: width, height: height)
            .background(ShotWallpaper(dark: dark))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 1))
    }
}

/// A window or menu: rounded, outlined, lifted off the wallpaper.
struct ShotLifted: ViewModifier {
    let dark: Bool
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14), lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .shadow(color: .black.opacity(dark ? 0.55 : 0.25), radius: 22, y: 12))
    }
}

extension View {
    func lifted(dark: Bool, radius: CGFloat = 12) -> some View { modifier(ShotLifted(dark: dark, radius: radius)) }
}

struct ShotMenuBar: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text("\u{F8FF}").font(.system(size: 15)).padding(.trailing, 18)
            Text("Finder").font(.system(size: 13, weight: .bold)).padding(.trailing, 16)
            ForEach(["File", "Edit", "View"], id: \.self) {
                Text($0).font(.system(size: 13)).padding(.trailing, 16)
            }
            Spacer()
            Image(nsImage: MenuBarIcon.status)
                .renderingMode(.template)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)))
                .padding(.trailing, 12)
            Image(systemName: "wifi").font(.system(size: 13, weight: .medium)).padding(.trailing, 14)
            Image(systemName: "battery.75percent").font(.system(size: 15)).padding(.trailing, 14)
            Text("Thu 10:41").font(.system(size: 13))
        }
        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(dark ? Color.black.opacity(0.30) : Color.white.opacity(0.45))
    }
}

// MARK: - Hero

struct ShotHero: View {
    let panel: NSImage
    let dark: Bool

    var body: some View {
        Stage(width: 470, height: 30 + 10 + panel.size.height + 40, dark: dark) {
            VStack(spacing: 0) {
                ShotMenuBar(dark: dark)
                HStack {
                    Spacer()
                    Image(nsImage: panel)
                        .lifted(dark: dark)
                        .padding(.trailing, 44)
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - ⇧⌘3

struct ShotScreen: View {
    let dark: Bool
    let captured: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShotWallpaper(dark: dark).opacity(captured ? 1 : 0.55)
            // Two windows, drawn as plain cards.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dark ? Color(white: 0.20) : Color(white: 0.98))
                .frame(width: 118, height: 84)
                .offset(x: 18, y: 22)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dark ? Color(white: 0.26) : Color.white)
                .frame(width: 96, height: 70)
                .offset(x: 108, y: 52)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .clipped()
    }
}

struct ShotPointer: View {
    var body: some View {
        Image(nsImage: NSImage(size: NSSize(width: 22, height: 28), flipped: false) { rect in
            let path = MenuBarIcon.pointer(in: rect.insetBy(dx: 2, dy: 2))
            NSColor.black.setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1.6
            path.stroke()
            return true
        })
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

struct ShotChip: View {
    let text: String
    let systemImage: String
    let strong: Bool
    let dark: Bool

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(strong ? Color.white : (dark ? Color.white.opacity(0.75) : Color.black.opacity(0.55)))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(strong ? brand : (dark ? Color.white.opacity(0.10) : Color.white.opacity(0.6))))
    }
}

struct CaptureScene: View {
    let dark: Bool

    var body: some View {
        Stage(width: 760, height: 340, dark: dark) {
            HStack(alignment: .bottom, spacing: 56) {
                // The main display: left alone.
                VStack(spacing: 14) {
                    VStack(spacing: 0) {
                        ShotScreen(dark: dark, captured: false)
                            .frame(width: 280, height: 158)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(white: dark ? 0.06 : 0.14)))
                        Rectangle().fill(Color(white: dark ? 0.30 : 0.62)).frame(width: 44, height: 30)
                        RoundedRectangle(cornerRadius: 3).fill(Color(white: dark ? 0.34 : 0.66)).frame(width: 110, height: 7)
                    }
                    .opacity(0.8)
                    ShotChip(text: "Main display", systemImage: "display", strong: false, dark: dark)
                }
                // The one under the pointer: captured.
                VStack(spacing: 14) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .bottomTrailing) {
                            ShotScreen(dark: dark, captured: true)
                                .frame(width: 236, height: 148)
                            // The preview, on the screen it came from.
                            ShotScreen(dark: dark, captured: true)
                                .frame(width: 236, height: 148)
                                .scaleEffect(0.28, anchor: .bottomTrailing)
                                .frame(width: 66, height: 41, alignment: .bottomTrailing)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                .padding(2)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white))
                                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                                .padding(8)
                            ShotPointer().offset(x: -120, y: -60)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(brand, lineWidth: 3))
                        .padding(8)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                            .fill(Color(white: dark ? 0.06 : 0.14)))
                        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                            .fill(Color(white: dark ? 0.36 : 0.78))
                            .frame(width: 290, height: 10)
                    }
                    ShotChip(text: "Captured", systemImage: "camera.viewfinder", strong: true, dark: dark)
                }
            }
        }
    }
}

// MARK: - ⇧⌘7

struct ShotToast: View {
    let message: String
    let dark: Bool

    var body: some View {
        Label(message, systemImage: "doc.on.clipboard")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(dark ? Color(white: 0.20) : Color(white: 0.97)))
            .overlay(Capsule().strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }
}

struct ShotCrosshair: View {
    var body: some View {
        ZStack {
            Rectangle().frame(width: 1.5, height: 22)
            Rectangle().frame(width: 22, height: 1.5)
        }
        .foregroundStyle(Color.black)
        .overlay(
            ZStack {
                Rectangle().frame(width: 3.5, height: 24)
                Rectangle().frame(width: 24, height: 3.5)
            }
            .foregroundStyle(Color.white)
            .blendMode(.destinationOver)
        )
        .compositingGroup()
    }
}

struct TextScene: View {
    let dark: Bool
    static let selected = "Network: Harbor Guest\nPassword: blue-harbor-72"

    var body: some View {
        let ink = dark ? Color.white : Color.black.opacity(0.85)
        let soft = dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
        Stage(width: 760, height: 340, dark: dark) {
            VStack(spacing: 0) {
                // A shared screen in a video call: text you can see but not select.
                HStack(spacing: 7) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 11, height: 11)
                    }
                    Spacer()
                    Text("Weekly sync · Screen sharing").font(.system(size: 12, weight: .medium)).foregroundStyle(soft)
                    Spacer()
                    Color.clear.frame(width: 47)
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Welcome, visitors").font(.system(size: 28, weight: .bold)).foregroundStyle(ink)
                        Text("Network: Harbor Guest").font(.system(size: 19, weight: .medium)).foregroundStyle(ink)
                        Text("Password: blue-harbor-72").font(.system(size: 19, weight: .medium)).foregroundStyle(ink)
                        Text("Reception is on the 4th floor.").font(.system(size: 15)).foregroundStyle(soft)
                    }
                    .padding(.leading, 36)
                    .padding(.top, 22)
                    // macOS's own selection, dragged over the two lines.
                    Rectangle()
                        .fill(Color.gray.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(Color.gray.opacity(0.7), lineWidth: 1))
                        .frame(width: 282, height: 76)
                        .offset(x: 22, y: 58)
                    ShotCrosshair().offset(x: 293, y: 123)
                }
                .frame(width: 440, height: 186, alignment: .topLeading)
                .background(dark ? Color(white: 0.13) : Color.white)
            }
            .frame(width: 440)
            .background(dark ? Color(white: 0.18) : Color(white: 0.93))
            .lifted(dark: dark)
            .offset(y: 22)

            ShotToast(message: TextCaptureStrings.copied(Self.selected), dark: dark)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 20)
        }
    }
}

// MARK: - ⇧⌘8

struct HistoryScene: View {
    let picker: NSImage
    let dark: Bool

    var body: some View {
        Stage(width: 760, height: picker.size.height + 80, dark: dark) {
            Image(nsImage: picker).lifted(dark: dark, radius: 14)
        }
    }
}

// MARK: - Download button

struct DownloadButton: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 19, weight: .semibold))
            Text("Download for macOS").font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 24)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.56, green: 0.40, blue: 0.98), brand],
                                 startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: -

@main
struct ReadmeShots {
    @MainActor
    static func main() {
        let app = RenderApp.shared
        app.setActivationPolicy(.accessory)
        let out = CommandLine.arguments[1]

        let external = DisplayInfo(id: 90, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let laptop = DisplayInfo(id: 91, bounds: CGRect(x: 2560, y: 400, width: 1680, height: 1050))
        let model = PanelModel(takeover: .shared)
        model.sampleDisplays = { [external, laptop] }
        model.samplePointer = { CGPoint(x: 3300, y: 900) }
        model.posedNames = [90: "Studio Display", 91: "Built-in Retina"]
        model.posedState = (permission: true, isOn: true)
        model.refreshEnvironment()
        model.refresh()
        model.launchesAtLogin = true

        let now = Date()
        func drawing(_ w: Int, _ h: Int, _ hue: CGFloat) -> NSImage {
            NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
                NSColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).setFill(); r.fill()
                NSColor(white: 1, alpha: 0.9).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: r.width * 0.12, dy: r.height * 0.18), xRadius: 6, yRadius: 6).fill()
                NSColor(hue: hue, saturation: 0.7, brightness: 0.7, alpha: 1).setFill()
                for i in 0..<4 {
                    NSRect(x: r.width * 0.2, y: r.height * (0.62 - Double(i) * 0.12),
                           width: r.width * (0.55 - Double(i) * 0.08), height: r.height * 0.05).fill()
                }
                return true
            }
        }
        let shot = ClipImage(digest: "shot", format: .png, width: 1680, height: 1050, byteCount: 2_100_000)
        let photo = ClipImage(digest: "photo", format: .jpeg, width: 1200, height: 1600, byteCount: 420_000)
        let history = ClipboardHistory.empty
            .adding("Thanks, see you Thursday!", source: "Messages", at: now.addingTimeInterval(-5400))
            .adding("git push origin main --tags", source: "Terminal", at: now.addingTimeInterval(-2400))
            .adding(image: photo, source: "Safari", at: now.addingTimeInterval(-1500))
            .adding("https://github.com/adrbn/screenhere", source: "Safari", at: now.addingTimeInterval(-900))
            .adding("Sync moved to Thursday 10:00, room 4B.", source: "Mail", at: now.addingTimeInterval(-300))
            .adding(TextScene.selected, source: "ScreenHere", at: now.addingTimeInterval(-40))
            .adding(image: shot, source: "ScreenHere", at: now.addingTimeInterval(-12))
        ClipboardController.shared.pose(history, enabled: true,
                                        thumbnails: ["shot": drawing(240, 150, 0.72), "photo": drawing(180, 240, 0.08)])

        let panelView = PanelView(model: model, onRestoreShortcuts: {}, onHideIcon: {},
                                  onCheckUpdates: {}, onOpenGitHub: {}, onQuit: {})
        let picker = HistoryPickerModel(clipboard: .shared)
        picker.selection = 1

        if CommandLine.arguments.count > 2 {
            export(DownloadButton(), dark: false, to: "\(out)/download.png")
            return
        }
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            let panel = snapshot(panelView.padding(.vertical, 4)
                                    .background(dark ? Color(white: 0.155).opacity(0.94) : Color(white: 0.975).opacity(0.93)),
                                 width: 300, dark: dark, background: .clear)
            export(ShotHero(panel: panel, dark: dark), dark: dark, to: "\(out)/hero-\(name).png")
            export(CaptureScene(dark: dark), dark: dark, to: "\(out)/capture-\(name).png")
            export(TextScene(dark: dark), dark: dark, to: "\(out)/text-\(name).png")
            let pickerImage = snapshot(HistoryPickerView(model: picker, clipboard: .shared, links: .shared),
                                       width: 540, height: 420, dark: dark, background: .clear, key: false)
            export(HistoryScene(picker: pickerImage, dark: dark), dark: dark, to: "\(out)/history-\(name).png")
        }
    }
}
