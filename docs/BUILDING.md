# Building ScreenHere

```bash
swift build              # compile
swift test               # run the unit tests
./scripts/install.sh     # build, sign, install into /Applications, relaunch
./scripts/build-dmg.sh   # produce build/ScreenHere.dmg
```

Native Swift and SwiftUI, one dependency ([Sparkle](https://sparkle-project.org)), macOS 13 Ventura and later.

`build-dmg.sh` picks up a **Developer ID Application** identity from the keychain automatically and falls back to ad-hoc signing when none is present. It also embeds `Sparkle.framework` into the bundle, which SwiftPM does not do on its own, and re-signs Sparkle's nested helpers before sealing the app: they ship with their own signature, which Apple rejects at notarization and which stops Sparkle from launching its own installer.

> Ad-hoc signing is a trap here, not just a Gatekeeper nuisance. TCC keys the Screen Recording grant to the app's designated requirement, which for an ad-hoc binary is its `cdhash`, a value that changes on every single build. The toggle in System Settings keeps *looking* enabled while `tccd` quietly denies every capture, and you get re-prompted forever. Developer ID pins the requirement to the team instead, and the grant survives rebuilds.

> `swift run` launches the bare executable, which has no `Info.plist` identity, so `LSUIElement`, Launch at Login and the Screen Recording grant only behave correctly from the packaged `.app`. Always test the installed app.

The app icon is an Icon Composer document, `Resources/AppIcon.icon`, compiled by `actool` during the build (it ships with Xcode 26; without it the app builds with no icon). The README pictures are drawn by `scripts/readme-shots.sh`. Releases are covered in [RELEASING.md](RELEASING.md).

## Finding your way around

The codebase is small and well tested. Good places to start:

- [`CursorDisplay.swift`](../Sources/ScreenHere/CursorDisplay.swift): which display the pointer is on.
- [`TakeoverController.swift`](../Sources/ScreenHere/TakeoverController.swift): borrowing the shortcut and giving it back.
- [`WindowUnderPointer.swift`](../Sources/ScreenHere/WindowUnderPointer.swift): which window the pointer is on, for the window capture beta.
- [`KeyShortcut.swift`](../Sources/ScreenHere/KeyShortcut.swift): the window shortcut the user records, its rules and how its keys are written, with the field itself in [`ShortcutRecorder.swift`](../Sources/ScreenHere/ShortcutRecorder.swift).
- [`PanelView.swift`](../Sources/ScreenHere/PanelView.swift): the menu-bar panel.

How each feature behaves is described in [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Issues and pull requests are welcome.
