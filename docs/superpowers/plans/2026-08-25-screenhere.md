# ScreenHere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu-bar agent that takes over `⇧⌘3` / `⌃⇧⌘3` so they capture the display the pointer is on, instead of the main display.

**Architecture:** ScreenHere disables the macOS symbolic hotkeys 28 and 29, registers the same two key combinations for itself with Carbon, and on each press resolves the display under the pointer and shells out to `/usr/sbin/screencapture` scoped to that display. The capture is never reimplemented — `screencapture -p` reuses the user's own macOS screenshot settings, so destination, format and sound stay native.

**Tech Stack:** Swift 5.9+, SwiftPM executable, AppKit, Carbon.HIToolbox (`RegisterEventHotKey`), CoreGraphics, ServiceManagement. Zero external dependencies. XCTest.

**Spec:** `docs/superpowers/specs/2026-08-25-screenhere-design.md`

## Global Constraints

- **Repository:** `/Users/adrien/vibecoding/claudecode_repos/screenhere` (already `git init`-ed, spec committed).
- **Deployment floor:** macOS 13.0. `Package.swift` declares `platforms: [.macOS(.v13)]`; release builds pass `-Xswiftc -target -Xswiftc arm64-apple-macos13.0`. A Swift 6.4 toolchain otherwise stamps `minos = 27.0` and LaunchServices refuses the bundle with `kLSIncompatibleSystemVersionErr (-10825)`.
- **Zero external dependencies.** `Package.swift` has an empty `dependencies:` array and must stay that way.
- **Bundle identifier:** `com.screenhere.app`. **App name:** `ScreenHere`. **License:** MIT.
- **`LSUIElement = true`**, activation policy `.accessory` — no Dock icon, no main window.
- **All user-facing strings in English**, matching PodFidelity and Haze.
- **Never write a partial symbolic-hotkey dictionary.** Every write to `AppleSymbolicHotKeys` carries the complete original entry with only `enabled` changed; the untouched `value ▸ parameters` array is what makes the shortcut restorable.
- **No test may perform a real screen capture** or mutate `com.apple.symbolichotkeys`. System I/O is behind protocols; tests use fakes.
- **Symbolic hotkey IDs:** `28` = `⇧⌘3` (parameters `[51, 20, 1179648]`), `29` = `⌃⇧⌘3` (parameters `[51, 20, 1441792]`).

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Package.swift` | SwiftPM manifest, executable + test target | 1 |
| `Resources/Info.plist` | Bundle metadata, `LSUIElement` | 1 |
| `Sources/ScreenHere/main.swift` | Activation policy, delegate wiring | 1, 7 |
| `Sources/ScreenHere/CursorDisplay.swift` | Pointer position → `screencapture -D` index | 1 |
| `Sources/ScreenHere/SymbolicHotkeyPlist.swift` | Pure plist transforms on a hotkey entry | 2 |
| `Sources/ScreenHere/SymbolicHotkeys.swift` | `defaults` + `activateSettings` I/O behind a protocol | 2 |
| `Sources/ScreenHere/HotkeyRegistrar.swift` | Carbon `RegisterEventHotKey` binding | 3 |
| `Sources/ScreenHere/CaptureRunner.swift` | Builds and spawns the `screencapture` command | 4 |
| `Sources/ScreenHere/TakeoverController.swift` | Owns enable/disable/restore/self-heal; the app's brain | 5 |
| `Sources/ScreenHere/MenuBarIcon.swift` | Code-drawn template glyph | 6 |
| `Sources/ScreenHere/MenuBarController.swift` | `NSStatusItem` + `NSMenu` | 6 |
| `Sources/ScreenHere/LoginItem.swift` | `SMAppService` wrapper (ported from PodFidelity) | 6 |
| `Sources/ScreenHere/UpdateChecker.swift` | GitHub Releases check (ported from PodFidelity) | 6 |
| `Sources/ScreenHere/AppDelegate.swift` | Lifecycle, single instance, restore on terminate | 7 |
| `scripts/build-dmg.sh` | Release build → `.app` → ad-hoc sign → DMG | 8 |
| `scripts/make-icon.swift` | Generates the `.iconset` | 8 |
| `README.md`, `.github/workflows/*` | Docs and CI | 8 |

`TakeoverController.swift` is an addition to the spec's file table, made during planning: without it the enable/disable/restore state machine would live in `MenuBarController`, where it could not be unit-tested.

---

### Task 1: Project skeleton and display resolution

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE`, `Resources/Info.plist`, `Sources/ScreenHere/main.swift`, `Sources/ScreenHere/CursorDisplay.swift`
- Test: `Tests/ScreenHereTests/CursorDisplayTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct DisplayInfo: Equatable { let id: CGDirectDisplayID; let bounds: CGRect }`; `CursorDisplay.captureIndex(for:in:mainDisplayID:) -> Int`; `CursorDisplay.activeDisplays() -> [DisplayInfo]`; `CursorDisplay.cursorLocation() -> CGPoint`; `CursorDisplay.currentCaptureIndex() -> Int`; `CursorDisplay.displayName(at:) -> String?`.

- [ ] **Step 1: Scaffold the package**

`Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenHere",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenHere",
            path: "Sources/ScreenHere"
        ),
        .testTarget(
            name: "ScreenHereTests",
            dependencies: ["ScreenHere"],
            path: "Tests/ScreenHereTests"
        ),
    ]
)
```

`.gitignore`:

```
.build/
.DS_Store
build/
Resources/AppIcon.icns
Resources/AppIcon.iconset/
*.xcuserstate
```

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ScreenHere</string>
    <key>CFBundleDisplayName</key>
    <string>ScreenHere</string>
    <key>CFBundleIdentifier</key>
    <string>com.screenhere.app</string>
    <key>CFBundleExecutable</key>
    <string>ScreenHere</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. ScreenHere contributors.</string>
</dict>
</plist>
```

`Sources/ScreenHere/main.swift` (expanded in Task 7):

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; menu-bar only
app.run()
```

`LICENSE`: the standard MIT text, `Copyright (c) 2026 ScreenHere contributors`.

- [ ] **Step 2: Write the failing test**

`Tests/ScreenHereTests/CursorDisplayTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import ScreenHere

/// Display layout of the machine this was designed on, in CoreGraphics
/// coordinates (origin top-left). Index in the array is the order
/// `CGGetActiveDisplayList` returns, which is exactly what `-D` indexes.
private enum Layout {
    /// External MSI MD271UL, the main display, at the origin.
    static let external = DisplayInfo(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    /// Built-in Retina display, placed to its right.
    static let builtIn = DisplayInfo(id: 1, bounds: CGRect(x: 2560, y: 0, width: 1680, height: 1050))
    static let both = [external, builtIn]
}

final class CursorDisplayTests: XCTestCase {

    func testPointerOnMainDisplayResolvesToD1() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 100, y: 100), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 1)
    }

    func testPointerOnSecondaryDisplayResolvesToD2() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 3000, y: 500), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 2)
    }

    /// The seam between the two displays belongs to the display whose bounds
    /// start there — CGRect.contains is inclusive of minX, exclusive of maxX.
    func testPointerOnTheSeamBelongsToTheDisplayItStarts() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 2560, y: 0), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 2)
    }

    func testPointerOutsideEveryDisplayFallsBackToMain() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 99_999, y: 99_999), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 1)
    }

    /// The main display is not always first in the list; the fallback must
    /// resolve by identifier, not by position.
    func testFallbackFindsMainDisplayWhereverItSitsInTheList() {
        let reordered = [Layout.builtIn, Layout.external]
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: -5000, y: 0), in: reordered, mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 2)
    }

    func testSingleDisplaySetupAlwaysResolvesToD1() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 400, y: 400), in: [Layout.external], mainDisplayID: Layout.external.id)
        XCTAssertEqual(index, 1)
    }

    /// Mirrored displays share identical bounds. `screencapture` addresses a
    /// mirror set through its first member, which is what list order gives us.
    func testMirroredDisplaysResolveToTheFirstOfTheSet() {
        let mirrorA = DisplayInfo(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let mirrorB = DisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 800, y: 600), in: [mirrorA, mirrorB], mainDisplayID: mirrorA.id)
        XCTAssertEqual(index, 1)
    }

    /// Unplugging a display renumbers every index. Because the index is derived
    /// from the display list on each call and never cached, the pointer keeps
    /// resolving to the right screen across a topology change.
    func testIndexFollowsATopologyChange() {
        let before = CursorDisplay.captureIndex(
            for: CGPoint(x: 3000, y: 500), in: Layout.both, mainDisplayID: Layout.external.id)
        XCTAssertEqual(before, 2)

        // External display unplugged: the built-in one is all that is left.
        let after = CursorDisplay.captureIndex(
            for: CGPoint(x: 3000, y: 500), in: [Layout.builtIn], mainDisplayID: Layout.builtIn.id)
        XCTAssertEqual(after, 1)
    }

    /// A capture index is meaningless if we cannot enumerate displays; the
    /// caller must still receive a usable value rather than 0 or a crash.
    func testEmptyDisplayListStillYieldsAValidIndex() {
        let index = CursorDisplay.captureIndex(
            for: CGPoint(x: 0, y: 0), in: [], mainDisplayID: 0)
        XCTAssertEqual(index, 1)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter CursorDisplayTests`
Expected: FAIL — `cannot find 'DisplayInfo' in scope`.

- [ ] **Step 4: Write the implementation**

`Sources/ScreenHere/CursorDisplay.swift`:

```swift
import AppKit
import CoreGraphics

/// A display as `screencapture` sees it: an identifier plus its global bounds
/// in CoreGraphics coordinates (origin top-left, y grows downwards).
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

/// Resolves which display the pointer is on, as a `screencapture -D<n>` index.
enum CursorDisplay {

    /// 1-based index for `screencapture -D<n>`.
    ///
    /// `displays` must be in `CGGetActiveDisplayList` order: that order is
    /// exactly what `-D` indexes (verified on macOS 27.0 — `-D1` returned the
    /// main display at 5120×2880, `-D2` the built-in one at 3360×2100).
    /// Falls back to the main display when the pointer sits outside every
    /// display, and to 1 when the display list could not be read at all.
    static func captureIndex(for point: CGPoint,
                             in displays: [DisplayInfo],
                             mainDisplayID: CGDirectDisplayID) -> Int {
        if let hit = displays.firstIndex(where: { $0.bounds.contains(point) }) {
            return hit + 1
        }
        if let main = displays.firstIndex(where: { $0.id == mainDisplayID }) {
            return main + 1
        }
        return 1
    }

    // MARK: - Live system state

    /// Active displays in `CGGetActiveDisplayList` order. Empty if the list
    /// cannot be read, which the pure logic above degrades gracefully on.
    static func activeDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0)) }
    }

    /// Pointer position in global CoreGraphics coordinates. Read from a
    /// synthesised event rather than `NSEvent.mouseLocation` so it needs no
    /// coordinate flip and stays correct without a key window.
    static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The index to hand `screencapture` right now. Recomputed on every call —
    /// never cached, so hot-plugging a display between two captures is fine.
    static func currentCaptureIndex() -> Int {
        captureIndex(for: cursorLocation(),
                     in: activeDisplays(),
                     mainDisplayID: CGMainDisplayID())
    }

    /// Human-readable name of the display holding `point`, for the menu.
    static func displayName(at point: CGPoint) -> String? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayBounds(number.uint32Value).contains(point)
        }?.localizedName
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore LICENSE Resources Sources Tests
git commit -m "feat: resolve the screencapture display index under the pointer"
```

---

### Task 2: Symbolic hotkey read, disable and restore

**Files:**
- Create: `Sources/ScreenHere/SymbolicHotkeyPlist.swift`, `Sources/ScreenHere/SymbolicHotkeys.swift`
- Test: `Tests/ScreenHereTests/SymbolicHotkeyPlistTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `enum SymbolicHotkeyPlist` with `static func isEnabled(_:) -> Bool`, `static func disabled(_:) -> [String: Any]`, `static func xml(from:) throws -> String`, `static func entry(fromXML:) throws -> [String: Any]`, and `static let screenshotToDestination = 28` / `static let screenshotToClipboard = 29`; `protocol SymbolicHotkeyStore` with `func entry(_ id: Int) -> [String: Any]?`, `func write(_ entry: [String: Any], for id: Int) throws`, `@discardableResult func applyNow() -> Bool`; `struct DefaultsSymbolicHotkeyStore: SymbolicHotkeyStore`.

- [ ] **Step 1: Write the failing test**

`Tests/ScreenHereTests/SymbolicHotkeyPlistTests.swift`:

```swift
import XCTest
@testable import ScreenHere

final class SymbolicHotkeyPlistTests: XCTestCase {

    /// The real macOS entry for ⇧⌘3, read from com.apple.symbolichotkeys.
    /// 51 = ASCII "3", 20 = kVK_ANSI_3, 1179648 = shift + command.
    private func shk28() -> [String: Any] {
        [
            "enabled": true,
            "value": [
                "type": "standard",
                "parameters": [51, 20, 1179648],
            ] as [String: Any],
        ]
    }

    func testReadsTheEnabledFlag() {
        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(shk28()))
        XCTAssertFalse(SymbolicHotkeyPlist.isEnabled(SymbolicHotkeyPlist.disabled(shk28())))
    }

    func testMissingEnabledFlagCountsAsDisabled() {
        XCTAssertFalse(SymbolicHotkeyPlist.isEnabled(["value": ["type": "standard"]]))
    }

    /// The whole point of the app's restore path: disabling must not eat the
    /// parameters array, or the shortcut stays dead even after we re-enable it.
    func testDisablingPreservesEverythingElseVerbatim() {
        let disabled = SymbolicHotkeyPlist.disabled(shk28())
        let value = disabled["value"] as? [String: Any]
        XCTAssertEqual(value?["type"] as? String, "standard")
        XCTAssertEqual(value?["parameters"] as? [Int], [51, 20, 1179648])
    }

    func testDisablingDoesNotMutateTheOriginal() {
        let original = shk28()
        _ = SymbolicHotkeyPlist.disabled(original)
        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(original))
    }

    func testXMLRoundTripIsLossless() throws {
        let original = shk28()
        let restored = try SymbolicHotkeyPlist.entry(fromXML: SymbolicHotkeyPlist.xml(from: original))
        XCTAssertEqual(NSDictionary(dictionary: restored), NSDictionary(dictionary: original))
    }

    func testXMLIsAcceptableToDefaultsWrite() throws {
        let xml = try SymbolicHotkeyPlist.xml(from: SymbolicHotkeyPlist.disabled(shk28()))
        XCTAssertTrue(xml.contains("<key>enabled</key>"))
        XCTAssertTrue(xml.contains("<false/>"))
        XCTAssertTrue(xml.contains("<integer>1179648</integer>"))
    }

    func testMalformedXMLThrowsRatherThanReturningAnEmptyEntry() {
        XCTAssertThrowsError(try SymbolicHotkeyPlist.entry(fromXML: "not a plist"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SymbolicHotkeyPlistTests`
Expected: FAIL — `cannot find 'SymbolicHotkeyPlist' in scope`.

- [ ] **Step 3: Write the pure implementation**

`Sources/ScreenHere/SymbolicHotkeyPlist.swift`:

```swift
import Foundation

/// Pure transforms on one entry of the `AppleSymbolicHotKeys` dictionary.
///
/// An entry looks like:
/// ```
/// { enabled = 1; value = { type = standard; parameters = (51, 20, 1179648); }; }
/// ```
/// where `parameters` is `[charCode, keyCode, modifierMask]`. The modifier
/// mask uses the Cocoa bits: shift 131072, control 262144, option 524288,
/// command 1048576.
enum SymbolicHotkeyPlist {

    /// "Save picture of screen" — ⇧⌘3.
    static let screenshotToDestination = 28
    /// "Copy picture of screen to the clipboard" — ⌃⇧⌘3.
    static let screenshotToClipboard = 29

    enum Failure: Error, LocalizedError {
        case notAPropertyList
        case notADictionary
        case notUTF8

        var errorDescription: String? {
            switch self {
            case .notAPropertyList: return "The hotkey entry is not a valid property list."
            case .notADictionary: return "The hotkey entry is not a dictionary."
            case .notUTF8: return "The hotkey entry could not be encoded as UTF-8."
            }
        }
    }

    static func isEnabled(_ entry: [String: Any]) -> Bool {
        (entry["enabled"] as? NSNumber)?.boolValue ?? false
    }

    /// A copy of `entry` with `enabled` false and every other key preserved
    /// verbatim — including `value ▸ parameters`, without which macOS cannot
    /// re-arm the shortcut when we hand it back.
    static func disabled(_ entry: [String: Any]) -> [String: Any] {
        var copy = entry
        copy["enabled"] = false
        return copy
    }

    /// XML plist text, the form `defaults write … -dict-add` accepts.
    static func xml(from entry: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entry, format: .xml, options: 0)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }

    static func entry(fromXML xml: String) throws -> [String: Any] {
        guard let data = xml.data(using: .utf8) else { throw Failure.notUTF8 }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) else { throw Failure.notAPropertyList }
        guard let dictionary = object as? [String: Any] else { throw Failure.notADictionary }
        return dictionary
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SymbolicHotkeyPlistTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Write the system-I/O layer**

`Sources/ScreenHere/SymbolicHotkeys.swift`. It shells out to `/usr/bin/defaults` rather than using `CFPreferences`, because `com.apple.symbolichotkeys` is owned by the system and `cfprefsd` may serve a stale in-process cache.

```swift
import Foundation

/// Read/write access to the macOS symbolic hotkeys, behind a protocol so the
/// controller can be tested without touching the user's real preferences.
protocol SymbolicHotkeyStore {
    /// The complete current entry for a symbolic hotkey id, or nil if absent.
    func entry(_ id: Int) -> [String: Any]?
    /// Merges `entry` into `AppleSymbolicHotKeys` under `id`.
    func write(_ entry: [String: Any], for id: Int) throws
    /// Asks the window server to re-read the hotkey table. Returns false when
    /// the change will only take effect at the next login.
    @discardableResult func applyNow() -> Bool
}

struct DefaultsSymbolicHotkeyStore: SymbolicHotkeyStore {
    private static let domain = "com.apple.symbolichotkeys"
    private static let key = "AppleSymbolicHotKeys"
    private static let activateSettings =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    enum Failure: Error, LocalizedError {
        case writeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let code):
                return "`defaults write` failed with exit code \(code)."
            }
        }
    }

    func entry(_ id: Int) -> [String: Any]? {
        // `defaults export` goes through cfprefsd, so it always reflects
        // pending writes — reading the .plist file directly does not.
        guard let output = Self.run("/usr/bin/defaults",
                                    ["export", Self.domain, "-"]).standardOutput,
              let plist = try? PropertyListSerialization.propertyList(
                  from: output, options: [], format: nil) as? [String: Any],
              let table = plist[Self.key] as? [String: Any],
              let raw = table[String(id)] as? [String: Any]
        else { return nil }
        return raw
    }

    func write(_ entry: [String: Any], for id: Int) throws {
        let xml = try SymbolicHotkeyPlist.xml(from: entry)
        let result = Self.run("/usr/bin/defaults",
                              ["write", Self.domain, Self.key, "-dict-add", String(id), xml])
        guard result.status == 0 else { throw Failure.writeFailed(result.status) }
    }

    @discardableResult
    func applyNow() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.activateSettings) else {
            return false
        }
        return Self.run(Self.activateSettings, ["-u"]).status == 0
    }

    // MARK: - Process helper

    private static func run(_ path: String, _ arguments: [String])
        -> (status: Int32, standardOutput: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
```

- [ ] **Step 6: Verify the full build and test suite still pass**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 7: Manually confirm the disable/restore cycle works on this machine**

This is the plan's one genuine unknown: whether `activateSettings -u` still re-arms the hotkey table live on macOS 27.0. Run these by hand and watch `⇧⌘3` between them. **Run the restore step even if an earlier step fails** — leaving it disabled costs the user their screenshot shortcut.

```bash
defaults export com.apple.symbolichotkeys - | plutil -extract AppleSymbolicHotKeys.28 xml1 -o - -
```

```bash
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 28 '<dict><key>enabled</key><false/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>51</integer><integer>20</integer><integer>1179648</integer></array></dict></dict>' && /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

Press `⇧⌘3`: it must do nothing at all. Then restore:

```bash
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 28 '<dict><key>enabled</key><true/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>51</integer><integer>20</integer><integer>1179648</integer></array></dict></dict>' && /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

Press `⇧⌘3` again: the normal macOS capture must be back. Record the outcome in the commit message. If `activateSettings -u` turns out not to apply live, the code path is unchanged — `applyNow()` returns false and Task 6 surfaces "Log out to finish enabling" in the menu.

- [ ] **Step 8: Commit**

```bash
git add Sources/ScreenHere/SymbolicHotkeyPlist.swift Sources/ScreenHere/SymbolicHotkeys.swift Tests/ScreenHereTests/SymbolicHotkeyPlistTests.swift
git commit -m "feat: read, disable and restore the macOS screenshot symbolic hotkeys"
```

---

### Task 3: Carbon hotkey binding

**Files:**
- Create: `Sources/ScreenHere/HotkeyRegistrar.swift`
- Test: `Tests/ScreenHereTests/HotkeyRegistrarTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct HotkeyCombo: Equatable { let id: UInt32; let keyCode: UInt32; let carbonModifiers: UInt32 }` with `static let screenshotToDestination` and `static let screenshotToClipboard`, and `var cocoaModifierMask: Int`; `protocol HotkeyBinding: AnyObject` with `func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool` and `func unbindAll()`; `final class HotkeyRegistrar: HotkeyBinding`.

- [ ] **Step 1: Write the failing test**

`Tests/ScreenHereTests/HotkeyRegistrarTests.swift`:

```swift
import Carbon.HIToolbox
import XCTest
@testable import ScreenHere

/// Carbon and the symbolic-hotkey plist describe the same key combination with
/// two different modifier encodings. If they ever disagree, ScreenHere would
/// disable one shortcut and register a different one — so the correspondence
/// is pinned by tests rather than by eyeballing.
final class HotkeyRegistrarTests: XCTestCase {

    func testBothCombosUseTheNumberThreeKey() {
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.keyCode, UInt32(kVK_ANSI_3))
        XCTAssertEqual(HotkeyCombo.screenshotToClipboard.keyCode, UInt32(kVK_ANSI_3))
        // 20 is the value macOS stores in the symbolic-hotkey parameters array.
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.keyCode, 20)
    }

    func testShiftCommandMatchesSymbolicHotkey28() {
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.cocoaModifierMask, 1_179_648)
    }

    func testControlShiftCommandMatchesSymbolicHotkey29() {
        XCTAssertEqual(HotkeyCombo.screenshotToClipboard.cocoaModifierMask, 1_441_792)
    }

    func testCombosHaveDistinctIdentifiers() {
        XCTAssertNotEqual(HotkeyCombo.screenshotToDestination.id,
                          HotkeyCombo.screenshotToClipboard.id)
    }

    func testCarbonModifiersAreTheCarbonConstants() {
        XCTAssertEqual(HotkeyCombo.screenshotToDestination.carbonModifiers,
                       UInt32(shiftKey | cmdKey))
        XCTAssertEqual(HotkeyCombo.screenshotToClipboard.carbonModifiers,
                       UInt32(shiftKey | cmdKey | controlKey))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter HotkeyRegistrarTests`
Expected: FAIL — `cannot find 'HotkeyCombo' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ScreenHere/HotkeyRegistrar.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// One key combination ScreenHere takes over, described in both encodings it
/// needs: Carbon's for `RegisterEventHotKey`, Cocoa's for cross-checking
/// against the symbolic-hotkey entry we disable.
struct HotkeyCombo: Equatable {
    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32

    /// ⇧⌘3 — mirrors symbolic hotkey 28.
    static let screenshotToDestination = HotkeyCombo(
        id: 1, keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(shiftKey | cmdKey))

    /// ⌃⇧⌘3 — mirrors symbolic hotkey 29.
    static let screenshotToClipboard = HotkeyCombo(
        id: 2, keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(shiftKey | cmdKey | controlKey))

    /// The same modifiers in the Cocoa bit layout macOS stores in
    /// `AppleSymbolicHotKeys ▸ value ▸ parameters[2]`.
    var cocoaModifierMask: Int {
        var mask = 0
        if carbonModifiers & UInt32(shiftKey) != 0 { mask |= Int(NSEvent.ModifierFlags.shift.rawValue) }
        if carbonModifiers & UInt32(controlKey) != 0 { mask |= Int(NSEvent.ModifierFlags.control.rawValue) }
        if carbonModifiers & UInt32(optionKey) != 0 { mask |= Int(NSEvent.ModifierFlags.option.rawValue) }
        if carbonModifiers & UInt32(cmdKey) != 0 { mask |= Int(NSEvent.ModifierFlags.command.rawValue) }
        return mask
    }
}

/// Registering global key combinations, behind a protocol so the controller
/// can be tested without touching the real event system.
protocol HotkeyBinding: AnyObject {
    /// Registers every combo. Returns false if any registration failed, in
    /// which case nothing stays registered.
    func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool
    func unbindAll()
}

/// Carbon `RegisterEventHotKey`. Chosen over `NSEvent` monitors because those
/// observe without consuming, and over a `CGEventTap` because taps need
/// Accessibility permission and get disarmed by the input watchdog.
final class HotkeyRegistrar: HotkeyBinding {
    private static let signature: OSType = 0x53_43_52_48   // 'SCRH'

    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var onFire: ((UInt32) -> Void)?

    func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool {
        unbindAll()
        self.onFire = onFire
        installHandlerIfNeeded()

        for combo in combos {
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: combo.id)
            let status = RegisterEventHotKey(
                combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0,
                &reference)
            guard status == noErr, let reference else {
                unbindAll()          // all or nothing: never half-registered
                return false
            }
            references.append(reference)
        }
        return true
    }

    func unbindAll() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, hotKeyID.signature == HotkeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                registrar.onFire?(hotKeyID.id)
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unbindAll()
        if let handler { RemoveEventHandler(handler) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HotkeyRegistrarTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScreenHere/HotkeyRegistrar.swift Tests/ScreenHereTests/HotkeyRegistrarTests.swift
git commit -m "feat: register the borrowed shortcuts with Carbon"
```

---

### Task 4: Capture command

**Files:**
- Create: `Sources/ScreenHere/CaptureRunner.swift`
- Test: `Tests/ScreenHereTests/CaptureRunnerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `enum CaptureDestination { case userSettings, clipboard }`; `enum CaptureRunner` with `static func arguments(destination:displayIndex:) -> [String]`, `static func run(destination:displayIndex:)`, `static var hasScreenRecordingPermission: Bool`, `static func requestScreenRecordingPermission()`.

- [ ] **Step 1: Write the failing test**

`Tests/ScreenHereTests/CaptureRunnerTests.swift`:

```swift
import XCTest
@testable import ScreenHere

final class CaptureRunnerTests: XCTestCase {

    /// `-p` makes screencapture reuse the user's own macOS screenshot
    /// settings — destination, folder, format, sound — so ⇧⌘3 keeps behaving
    /// exactly as they configured it, only on the right display.
    func testDefaultDestinationDefersToTheUsersSettings() {
        XCTAssertEqual(CaptureRunner.arguments(destination: .userSettings, displayIndex: 2),
                       ["-p", "-D2"])
    }

    /// ⌃⇧⌘3 means "to the clipboard" in macOS regardless of settings.
    func testClipboardDestinationForcesTheClipboard() {
        XCTAssertEqual(CaptureRunner.arguments(destination: .clipboard, displayIndex: 1),
                       ["-c", "-D1"])
    }

    func testDisplayIndexIsInterpolatedWithoutASpace() {
        // `screencapture` parses -D as an attached-argument flag; "-D 2" fails.
        let arguments = CaptureRunner.arguments(destination: .userSettings, displayIndex: 3)
        XCTAssertTrue(arguments.contains("-D3"))
        XCTAssertFalse(arguments.contains("-D"))
    }

    /// CursorDisplay never returns less than 1, but a clamped floor here means
    /// a future caller cannot produce "-D0" and silently capture nothing.
    func testIndexIsClampedToAValidDisplay() {
        XCTAssertEqual(CaptureRunner.arguments(destination: .clipboard, displayIndex: 0),
                       ["-c", "-D1"])
        XCTAssertEqual(CaptureRunner.arguments(destination: .clipboard, displayIndex: -7),
                       ["-c", "-D1"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CaptureRunnerTests`
Expected: FAIL — `cannot find 'CaptureRunner' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ScreenHere/CaptureRunner.swift`:

```swift
import CoreGraphics
import Foundation

enum CaptureDestination: Equatable {
    /// Whatever the user configured in the Screenshot app: `-p`.
    case userSettings
    /// Forced to the clipboard, the meaning of the Control modifier: `-c`.
    case clipboard
}

/// Runs the system screenshot binary, scoped to one display.
///
/// ScreenHere deliberately does not capture pixels itself. Delegating to
/// `/usr/sbin/screencapture` inherits the user's destination, folder, file
/// format and shutter sound for free, and keeps working if they change those
/// settings later.
enum CaptureRunner {
    private static let executable = "/usr/sbin/screencapture"

    /// Verified on macOS 27.0: `-p` honours `-D`, so `-p -D2` routes a capture
    /// of display 2 through the user's configured destination.
    static func arguments(destination: CaptureDestination, displayIndex: Int) -> [String] {
        let index = max(1, displayIndex)
        switch destination {
        case .userSettings: return ["-p", "-D\(index)"]
        case .clipboard: return ["-c", "-D\(index)"]
        }
    }

    static func run(destination: CaptureDestination, displayIndex: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(destination: destination, displayIndex: displayIndex)
        try? process.run()
    }

    /// TCC attributes the `screencapture` child to ScreenHere as the
    /// responsible process, so this reflects ScreenHere's own grant.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CaptureRunnerTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScreenHere/CaptureRunner.swift Tests/ScreenHereTests/CaptureRunnerTests.swift
git commit -m "feat: delegate the capture to screencapture on one display"
```

---

### Task 5: Takeover state machine

**Files:**
- Create: `Sources/ScreenHere/TakeoverController.swift`
- Test: `Tests/ScreenHereTests/TakeoverControllerTests.swift`, `Tests/ScreenHereTests/Fakes.swift`

**Interfaces:**
- Consumes: `SymbolicHotkeyStore`, `SymbolicHotkeyPlist` (Task 2); `HotkeyBinding`, `HotkeyCombo` (Task 3); `CaptureRunner`, `CaptureDestination` (Task 4); `CursorDisplay` (Task 1).
- Produces: `final class TakeoverController` with `enum Status: Equatable { case off, on, onPendingLogout, failed(String) }`, `init(store:binding:defaults:capture:)`, `var status: Status`, `var isOn: Bool`, `func enable()`, `func disable()`, `func healAfterUncleanExit()`, `func fire(comboID:)`.

- [ ] **Step 1: Write the fakes**

`Tests/ScreenHereTests/Fakes.swift`:

```swift
import Foundation
@testable import ScreenHere

/// An in-memory stand-in for com.apple.symbolichotkeys.
final class FakeSymbolicHotkeyStore: SymbolicHotkeyStore {
    var entries: [Int: [String: Any]]
    var applyNowResult = true
    var writeError: Error?
    private(set) var applyNowCallCount = 0

    init(entries: [Int: [String: Any]] = [
        SymbolicHotkeyPlist.screenshotToDestination: FakeSymbolicHotkeyStore.entry(modifiers: 1_179_648),
        SymbolicHotkeyPlist.screenshotToClipboard: FakeSymbolicHotkeyStore.entry(modifiers: 1_441_792),
    ]) {
        self.entries = entries
    }

    static func entry(modifiers: Int) -> [String: Any] {
        ["enabled": true,
         "value": ["type": "standard", "parameters": [51, 20, modifiers]] as [String: Any]]
    }

    func entry(_ id: Int) -> [String: Any]? { entries[id] }

    func write(_ entry: [String: Any], for id: Int) throws {
        if let writeError { throw writeError }
        entries[id] = entry
    }

    @discardableResult
    func applyNow() -> Bool {
        applyNowCallCount += 1
        return applyNowResult
    }
}

/// A stand-in for Carbon registration.
final class FakeHotkeyBinding: HotkeyBinding {
    var bindSucceeds = true
    private(set) var boundCombos: [HotkeyCombo] = []
    private(set) var unbindCallCount = 0
    private var onFire: ((UInt32) -> Void)?

    func bind(_ combos: [HotkeyCombo], onFire: @escaping (UInt32) -> Void) -> Bool {
        guard bindSucceeds else { return false }
        boundCombos = combos
        self.onFire = onFire
        return true
    }

    func unbindAll() {
        unbindCallCount += 1
        boundCombos = []
    }

    /// Simulates the user pressing a bound combination.
    func simulatePress(_ id: UInt32) { onFire?(id) }
}

/// Records capture requests instead of taking screenshots.
final class FakeCapture {
    private(set) var calls: [(destination: CaptureDestination, displayIndex: Int)] = []
    var displayIndexToReturn = 2

    func perform(destination: CaptureDestination, displayIndex: Int) {
        calls.append((destination, displayIndex))
    }
}

extension UserDefaults {
    /// A throwaway defaults domain so tests never touch the real one.
    static func makeTransient(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/ScreenHereTests/TakeoverControllerTests.swift`:

```swift
import XCTest
@testable import ScreenHere

final class TakeoverControllerTests: XCTestCase {

    private func makeController(
        store: FakeSymbolicHotkeyStore = FakeSymbolicHotkeyStore(),
        binding: FakeHotkeyBinding = FakeHotkeyBinding(),
        capture: FakeCapture = FakeCapture(),
        defaults: UserDefaults = .makeTransient()
    ) -> TakeoverController {
        TakeoverController(
            store: store, binding: binding, defaults: defaults,
            capture: { capture.perform(destination: $0, displayIndex: $1) },
            currentDisplayIndex: { capture.displayIndexToReturn })
    }

    // MARK: - Enabling

    func testEnablingDisablesBothSystemShortcuts() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.enable()

        for id in [SymbolicHotkeyPlist.screenshotToDestination,
                   SymbolicHotkeyPlist.screenshotToClipboard] {
            XCTAssertFalse(SymbolicHotkeyPlist.isEnabled(store.entries[id]!),
                           "symbolic hotkey \(id) should be disabled")
        }
        XCTAssertEqual(controller.status, .on)
    }

    func testEnablingPreservesTheParametersSoRestoreCanWork() {
        let store = FakeSymbolicHotkeyStore()
        makeController(store: store).enable()
        let value = store.entries[SymbolicHotkeyPlist.screenshotToDestination]?["value"] as? [String: Any]
        XCTAssertEqual(value?["parameters"] as? [Int], [51, 20, 1_179_648])
    }

    func testEnablingBindsBothCombos() {
        let binding = FakeHotkeyBinding()
        makeController(binding: binding).enable()
        XCTAssertEqual(binding.boundCombos,
                       [.screenshotToDestination, .screenshotToClipboard])
    }

    func testEnablingAsksTheWindowServerToReloadTheHotkeyTable() {
        let store = FakeSymbolicHotkeyStore()
        makeController(store: store).enable()
        XCTAssertEqual(store.applyNowCallCount, 1)
    }

    func testEnablingReportsPendingLogoutWhenTheChangeCannotBeAppliedLive() {
        let store = FakeSymbolicHotkeyStore()
        store.applyNowResult = false
        let controller = makeController(store: store)
        controller.enable()
        XCTAssertEqual(controller.status, .onPendingLogout)
    }

    /// If Carbon refuses the combos, macOS must get its shortcuts back
    /// immediately — otherwise ⇧⌘3 is dead for everyone.
    func testFailedBindingRollsTheSystemShortcutsBack() {
        let store = FakeSymbolicHotkeyStore()
        let binding = FakeHotkeyBinding()
        binding.bindSucceeds = false
        let controller = makeController(store: store, binding: binding)
        controller.enable()

        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(
            store.entries[SymbolicHotkeyPlist.screenshotToDestination]!))
        XCTAssertFalse(controller.isOn)
        if case .failed = controller.status {} else {
            XCTFail("expected a failed status, got \(controller.status)")
        }
    }

    func testEnablingTwiceIsIdempotent() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.enable()
        controller.enable()
        // The second enable must not capture the already-disabled entry as
        // the "original", which would make restore a no-op forever.
        controller.disable()
        XCTAssertTrue(SymbolicHotkeyPlist.isEnabled(
            store.entries[SymbolicHotkeyPlist.screenshotToDestination]!))
    }

    // MARK: - Disabling

    func testDisablingRestoresTheOriginalEntriesVerbatim() {
        let store = FakeSymbolicHotkeyStore()
        let originals = store.entries
        let controller = makeController(store: store)
        controller.enable()
        controller.disable()

        for (id, original) in originals {
            XCTAssertEqual(NSDictionary(dictionary: store.entries[id]!),
                           NSDictionary(dictionary: original))
        }
        XCTAssertEqual(controller.status, .off)
    }

    func testDisablingUnbindsTheCombos() {
        let binding = FakeHotkeyBinding()
        let controller = makeController(binding: binding)
        controller.enable()
        controller.disable()
        XCTAssertTrue(binding.boundCombos.isEmpty)
    }

    // MARK: - Recovery

    /// The scenario that must never strand the user: ScreenHere disabled the
    /// shortcuts, then died before restoring them.
    func testHealAfterUncleanExitRestoresShortcutsFromTheStoredOriginals() {
        let defaults = UserDefaults.makeTransient()
        let store = FakeSymbolicHotkeyStore()
        let originals = store.entries

        // First life: enable, then vanish without disabling.
        makeController(store: store, defaults: defaults).enable()

        // Second life: a fresh controller over the same persisted state.
        let reborn = makeController(store: store, defaults: defaults)
        reborn.healAfterUncleanExit()

        for (id, original) in originals {
            XCTAssertEqual(NSDictionary(dictionary: store.entries[id]!),
                           NSDictionary(dictionary: original))
        }
        XCTAssertEqual(reborn.status, .off)
    }

    func testHealDoesNothingWhenScreenHereNeverTookOver() {
        let store = FakeSymbolicHotkeyStore()
        let controller = makeController(store: store)
        controller.healAfterUncleanExit()
        XCTAssertEqual(store.applyNowCallCount, 0)
        XCTAssertEqual(controller.status, .off)
    }

    // MARK: - Firing

    func testShiftCommandThreeCapturesTheDisplayUnderThePointerWithUserSettings() {
        let capture = FakeCapture()
        capture.displayIndexToReturn = 2
        let binding = FakeHotkeyBinding()
        makeController(binding: binding, capture: capture).enable()

        binding.simulatePress(HotkeyCombo.screenshotToDestination.id)

        XCTAssertEqual(capture.calls.count, 1)
        XCTAssertEqual(capture.calls.first?.displayIndex, 2)
        XCTAssertEqual(capture.calls.first?.destination, .userSettings)
    }

    func testControlShiftCommandThreeForcesTheClipboard() {
        let capture = FakeCapture()
        capture.displayIndexToReturn = 1
        let binding = FakeHotkeyBinding()
        makeController(binding: binding, capture: capture).enable()

        binding.simulatePress(HotkeyCombo.screenshotToClipboard.id)

        XCTAssertEqual(capture.calls.first?.displayIndex, 1)
        XCTAssertEqual(capture.calls.first?.destination, .clipboard)
    }

    func testUnknownComboIdentifierIsIgnored() {
        let capture = FakeCapture()
        let binding = FakeHotkeyBinding()
        makeController(binding: binding, capture: capture).enable()
        binding.simulatePress(99)
        XCTAssertTrue(capture.calls.isEmpty)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter TakeoverControllerTests`
Expected: FAIL — `cannot find 'TakeoverController' in scope`.

- [ ] **Step 4: Write the implementation**

`Sources/ScreenHere/TakeoverController.swift`:

```swift
import Foundation

/// Owns the whole "borrow the system shortcut" state machine: disabling the
/// macOS symbolic hotkeys, holding the same combinations, capturing the right
/// display, and — the part that matters most — always being able to give the
/// shortcuts back.
final class TakeoverController {

    enum Status: Equatable {
        case off
        case on
        /// Preferences written, but the window server did not reload them.
        case onPendingLogout
        case failed(String)
    }

    private enum Key {
        static let isOn = "TakeoverEnabled"
        /// Verbatim copies of the entries we replaced, keyed by hotkey id.
        static func original(_ id: Int) -> String { "OriginalSymbolicHotkey\(id)" }
    }

    private static let managedHotkeys = [
        SymbolicHotkeyPlist.screenshotToDestination,
        SymbolicHotkeyPlist.screenshotToClipboard,
    ]

    private let store: SymbolicHotkeyStore
    private let binding: HotkeyBinding
    private let defaults: UserDefaults
    private let capture: (CaptureDestination, Int) -> Void
    private let currentDisplayIndex: () -> Int

    private(set) var status: Status = .off

    var isOn: Bool {
        if case .off = status { return false }
        if case .failed = status { return false }
        return true
    }

    init(store: SymbolicHotkeyStore = DefaultsSymbolicHotkeyStore(),
         binding: HotkeyBinding = HotkeyRegistrar(),
         defaults: UserDefaults = .standard,
         capture: @escaping (CaptureDestination, Int) -> Void = { destination, index in
             CaptureRunner.run(destination: destination, displayIndex: index)
         },
         currentDisplayIndex: @escaping () -> Int = { CursorDisplay.currentCaptureIndex() }) {
        self.store = store
        self.binding = binding
        self.defaults = defaults
        self.capture = capture
        self.currentDisplayIndex = currentDisplayIndex
    }

    // MARK: - Enable / disable

    func enable() {
        guard !isOn else { return }   // never re-snapshot an already-disabled entry

        for id in Self.managedHotkeys {
            guard let entry = store.entry(id) else { continue }
            // Only snapshot an entry we have not already replaced, so a stale
            // "on" flag can never overwrite the real original with a disabled one.
            if SymbolicHotkeyPlist.isEnabled(entry) {
                saveOriginal(entry, for: id)
            }
            do {
                try store.write(SymbolicHotkeyPlist.disabled(entry), for: id)
            } catch {
                restoreOriginals()
                status = .failed(error.localizedDescription)
                return
            }
        }

        let applied = store.applyNow()

        guard binding.bind([.screenshotToDestination, .screenshotToClipboard],
                           onFire: { [weak self] id in self?.fire(comboID: id) }) else {
            restoreOriginals()
            status = .failed("Another app is already holding ⇧⌘3.")
            return
        }

        defaults.set(true, forKey: Key.isOn)
        status = applied ? .on : .onPendingLogout
    }

    func disable() {
        binding.unbindAll()
        restoreOriginals()
        status = .off
    }

    /// Called at launch. If a previous run disabled the shortcuts and never
    /// gave them back — a crash, a force quit, a logout mid-session — this
    /// puts them back before anything else happens.
    func healAfterUncleanExit() {
        guard defaults.bool(forKey: Key.isOn) else { return }
        restoreOriginals()
        status = .off
    }

    // MARK: - Firing

    func fire(comboID: UInt32) {
        let destination: CaptureDestination
        switch comboID {
        case HotkeyCombo.screenshotToDestination.id: destination = .userSettings
        case HotkeyCombo.screenshotToClipboard.id: destination = .clipboard
        default: return
        }
        capture(destination, currentDisplayIndex())
    }

    // MARK: - Original entries

    private func saveOriginal(_ entry: [String: Any], for id: Int) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: entry, format: .binary, options: 0) else { return }
        defaults.set(data, forKey: Key.original(id))
    }

    private func restoreOriginals() {
        for id in Self.managedHotkeys {
            guard let data = defaults.data(forKey: Key.original(id)),
                  let entry = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) as? [String: Any]
            else { continue }
            try? store.write(entry, for: id)
            defaults.removeObject(forKey: Key.original(id))
        }
        store.applyNow()
        defaults.set(false, forKey: Key.isOn)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS, all tests across the four suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScreenHere/TakeoverController.swift Tests/ScreenHereTests/TakeoverControllerTests.swift Tests/ScreenHereTests/Fakes.swift
git commit -m "feat: add the takeover state machine with unclean-exit recovery"
```

---

### Task 6: Menu bar

**Files:**
- Create: `Sources/ScreenHere/LoginItem.swift`, `Sources/ScreenHere/UpdateChecker.swift`, `Sources/ScreenHere/MenuBarIcon.swift`, `Sources/ScreenHere/MenuBarController.swift`
- Test: `Tests/ScreenHereTests/MenuBarControllerTests.swift`, `Tests/ScreenHereTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `TakeoverController` and its `Status` (Task 5), `CursorDisplay.displayName(at:)` and `CursorDisplay.cursorLocation()` (Task 1), `CaptureRunner.hasScreenRecordingPermission` (Task 4).
- Produces: `enum LoginItem` with `static var isEnabled: Bool` and `static func setEnabled(_:) throws`; `enum UpdateChecker` with `static let repository`, `static let repositoryURL`, `static let releasesPageURL`, `static var currentVersion: String`, `static func checkInteractively()`, `static func evaluate(current:data:status:error:) -> Outcome`, `static func isNewer(_:than:) -> Bool`; `enum MenuBarIcon { static func statusImage() -> NSImage }`; `final class MenuBarController: NSObject, NSMenuDelegate` with `init(takeover:)`, `static func statusText(_:permissionGranted:) -> String`, `static func targetText(displayName:) -> String`, `static func shortName(_:max:) -> String`, `var isIconVisible: Bool`, `func unhideIcon()`, `static let showIconNotification: Notification.Name`, `static var prefHideIcon: Bool`.

- [ ] **Step 1: Port LoginItem and UpdateChecker from PodFidelity**

`Sources/ScreenHere/LoginItem.swift`:

```swift
import ServiceManagement

/// Wraps SMAppService (macOS 13+). Note: reliable registration requires a
/// signed, installed .app; unsigned dev builds may report `.notRegistered`
/// or throw — the caller surfaces the error.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

Copy `Sources/PodFidelity/UpdateChecker.swift` from `../airpods_mic_fixer_reborn` to `Sources/ScreenHere/UpdateChecker.swift`, then change exactly three things: `repository` becomes `"adrbn/screenhere"`, both occurrences of `"PodFidelity "` in the alert text become `"ScreenHere "`, and delete nothing else. Also copy `Tests/PodFidelityTests/UpdateCheckerTests.swift` to `Tests/ScreenHereTests/UpdateCheckerTests.swift`, changing `@testable import PodFidelity` to `@testable import ScreenHere`.

- [ ] **Step 2: Write the failing test**

`Tests/ScreenHereTests/MenuBarControllerTests.swift`:

```swift
import XCTest
@testable import ScreenHere

/// Only the pure status-line logic is unit-tested; the AppKit menu wiring is
/// exercised by hand (Task 7, Step 6).
final class MenuBarControllerTests: XCTestCase {

    func testOnStatusNamesTheShortcutItHolds() {
        XCTAssertEqual(MenuBarController.statusText(.on, permissionGranted: true),
                       "⇧⌘3 captures the screen under your pointer")
    }

    func testOffStatusSaysMacOSIsBackInCharge() {
        XCTAssertEqual(MenuBarController.statusText(.off, permissionGranted: true),
                       "Off — macOS handles ⇧⌘3")
    }

    func testPendingLogoutStatusTellsTheUserWhatToDo() {
        XCTAssertEqual(MenuBarController.statusText(.onPendingLogout, permissionGranted: true),
                       "Log out to finish taking over ⇧⌘3")
    }

    /// A missing permission is more urgent than the takeover state — without
    /// it every capture silently produces nothing.
    func testMissingScreenRecordingPermissionOutranksTheOnStatus() {
        XCTAssertEqual(MenuBarController.statusText(.on, permissionGranted: false),
                       "Screen Recording permission needed")
    }

    func testFailedStatusSurfacesTheReason() {
        XCTAssertEqual(
            MenuBarController.statusText(.failed("Another app is already holding ⇧⌘3."),
                                         permissionGranted: true),
            "Couldn't take over: Another app is already holding ⇧⌘3.")
    }

    func testTargetLineNamesTheDisplayUnderThePointer() {
        XCTAssertEqual(MenuBarController.targetText(displayName: "Built-in Retina Display"),
                       "Pointer is on: Built-in Retina Display")
    }

    func testTargetLineDegradesWhenTheDisplayCannotBeNamed() {
        XCTAssertEqual(MenuBarController.targetText(displayName: nil),
                       "Pointer is on: unknown display")
    }

    func testLongDisplayNamesAreTruncated() {
        let short = MenuBarController.shortName("LG UltraFine 5K Display (Thunderbolt 3)")
        XCTAssertLessThanOrEqual(short.count, 26)
        XCTAssertTrue(short.hasSuffix("…"))
    }

    func testShortDisplayNamesArePreserved() {
        XCTAssertEqual(MenuBarController.shortName("MSI MD271UL"), "MSI MD271UL")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter MenuBarControllerTests`
Expected: FAIL — `cannot find 'MenuBarController' in scope`.

- [ ] **Step 4: Write the icon**

`Sources/ScreenHere/MenuBarIcon.swift`:

```swift
import AppKit

/// The menu-bar glyph: two overlapping displays with a pointer on the nearer
/// one — the app's whole idea in 18×18 points. Drawn in code rather than taken
/// from SF Symbols because no symbol says "this display, not that one", and a
/// single even-odd path stays crisp as a template image.
enum MenuBarIcon {

    static func statusImage() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()

            // Far display: a plain rounded rectangle, offset up and right.
            path.append(NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6.5, width: 10.5, height: 7.5),
                                     xRadius: 1.5, yRadius: 1.5))
            path.append(NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 7.5, height: 4.5),
                                     xRadius: 0.5, yRadius: 0.5))

            // Near display: filled, drawn over the far one.
            path.append(NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 11, height: 8),
                                     xRadius: 1.5, yRadius: 1.5))
            // Stand.
            path.append(NSBezierPath(rect: NSRect(x: 5.5, y: 0.5, width: 2, height: 1.5)))

            // Pointer, punched out of the near display by the even-odd rule.
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: 5, y: 8.5))
            pointer.line(to: NSPoint(x: 5, y: 3.5))
            pointer.line(to: NSPoint(x: 6.4, y: 4.9))
            pointer.line(to: NSPoint(x: 7.3, y: 3.1))
            pointer.line(to: NSPoint(x: 8.4, y: 3.6))
            pointer.line(to: NSPoint(x: 7.5, y: 5.4))
            pointer.line(to: NSPoint(x: 9.4, y: 5.6))
            pointer.close()
            path.append(pointer)

            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true   // let the menu bar tint it for light/dark
        return image
    }
}
```

- [ ] **Step 5: Write the controller**

`Sources/ScreenHere/MenuBarController.swift`:

```swift
import AppKit

/// The menu-bar presence: an icon, a status line, the on/off toggle, a live
/// readout of which display would be captured right now, and the controls.
/// The menu is rebuilt every time it opens so the readout is never stale.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let takeover: TakeoverController

    /// Posted by a second launch (`open -n`, or reopening the .app) to ask the
    /// running instance to reveal a hidden menu-bar icon.
    static let showIconNotification = Notification.Name("com.screenhere.app.ShowMenuBar")

    private static let hideIconKey = "HideMenuBarIcon"
    /// Longest display name rendered before truncating, so the menu stays narrow.
    private static let maxNameLength = 26

    static var prefHideIcon: Bool {
        UserDefaults.standard.bool(forKey: hideIconKey)
    }

    var isIconVisible: Bool { statusItem.isVisible }

    init(takeover: TakeoverController) {
        self.takeover = takeover
        super.init()
        if let button = statusItem.button {
            button.image = MenuBarIcon.statusImage()
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        populate(menu)
        applyIconVisibility()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    // MARK: - Menu construction

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let permission = CaptureRunner.hasScreenRecordingPermission

        let status = NSMenuItem(
            title: Self.statusText(takeover.status, permissionGranted: permission),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !permission {
            let grant = NSMenuItem(title: "Grant Screen Recording Permission…",
                                   action: #selector(grantPermission), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Capture the Screen Under the Pointer",
                                action: #selector(toggleTakeover), keyEquivalent: "")
        toggle.target = self
        toggle.state = takeover.isOn ? .on : .off
        menu.addItem(toggle)

        let target = NSMenuItem(
            title: Self.targetText(
                displayName: CursorDisplay.displayName(at: CursorDisplay.cursorLocation())),
            action: nil, keyEquivalent: "")
        target.isEnabled = false
        menu.addItem(target)

        menu.addItem(.separator())

        // Always present, whatever the state — this is the user's escape hatch
        // if a crash ever left the system shortcuts disabled.
        let restore = NSMenuItem(title: "Restore macOS Shortcuts",
                                 action: #selector(restoreShortcuts), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let hideIcon = NSMenuItem(title: "Hide Menu Bar Icon",
                                  action: #selector(toggleHideIcon), keyEquivalent: "")
        hideIcon.target = self
        hideIcon.state = isIconVisible ? .off : .on
        menu.addItem(hideIcon)

        let checkUpdates = NSMenuItem(title: "Check for Updates…",
                                      action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        menu.addItem(.separator())

        let github = NSMenuItem(title: "View on GitHub",
                                action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ScreenHere", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Pure text (unit-tested)

    static func statusText(_ status: TakeoverController.Status,
                           permissionGranted: Bool) -> String {
        if !permissionGranted, status != .off {
            return "Screen Recording permission needed"
        }
        switch status {
        case .on: return "⇧⌘3 captures the screen under your pointer"
        case .off: return "Off — macOS handles ⇧⌘3"
        case .onPendingLogout: return "Log out to finish taking over ⇧⌘3"
        case .failed(let reason): return "Couldn't take over: \(reason)"
        }
    }

    static func targetText(displayName: String?) -> String {
        "Pointer is on: \(shortName(displayName ?? "unknown display"))"
    }

    /// Truncates long display names with an ellipsis so the menu stays narrow.
    static func shortName(_ name: String, max: Int = maxNameLength) -> String {
        guard name.count > max else { return name }
        return name.prefix(max - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Icon visibility

    private func applyIconVisibility() {
        statusItem.isVisible = !Self.prefHideIcon
    }

    /// Reveals the icon for this session without changing the persisted
    /// preference, so reopening the .app is a way back from a hidden icon.
    func unhideIcon() {
        statusItem.isVisible = true
    }

    // MARK: - Actions

    @objc private func toggleTakeover() {
        if takeover.isOn {
            takeover.disable()
        } else {
            if !CaptureRunner.hasScreenRecordingPermission {
                CaptureRunner.requestScreenRecordingPermission()
            }
            takeover.enable()
            if case .failed(let reason) = takeover.status {
                let alert = NSAlert()
                alert.messageText = "Couldn't take over ⇧⌘3"
                alert.informativeText = reason
                alert.runModal()
            }
        }
    }

    @objc private func restoreShortcuts() {
        takeover.disable()
    }

    @objc private func grantPermission() {
        // Prompts only the first time; afterwards macOS stays silent, so send
        // the user straight to the pane where the switch actually lives.
        CaptureRunner.requestScreenRecordingPermission()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleHideIcon() {
        let nowHidden = isIconVisible
        if nowHidden {
            let alert = NSAlert()
            alert.messageText = "Hide menu bar icon?"
            alert.informativeText = """
                The icon will disappear but ScreenHere keeps running, and ⇧⌘3 \
                keeps capturing the screen under your pointer. To show the icon \
                again, open ScreenHere from /Applications or Spotlight.
                """
            alert.addButton(withTitle: "Hide")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertSecondButtonReturn { return }
        }
        UserDefaults.standard.set(nowHidden, forKey: Self.hideIconKey)
        statusItem.isVisible = !nowHidden
    }

    @objc private func checkForUpdates() {
        UpdateChecker.checkInteractively()
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(UpdateChecker.repositoryURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter MenuBarControllerTests`
Expected: PASS, 9 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/ScreenHere/LoginItem.swift Sources/ScreenHere/UpdateChecker.swift Sources/ScreenHere/MenuBarIcon.swift Sources/ScreenHere/MenuBarController.swift Tests/ScreenHereTests/MenuBarControllerTests.swift Tests/ScreenHereTests/UpdateCheckerTests.swift
git commit -m "feat: add the menu bar with a live pointer-display readout"
```

---

### Task 7: App lifecycle, and the first real run

**Files:**
- Create: `Sources/ScreenHere/AppDelegate.swift`
- Modify: `Sources/ScreenHere/main.swift`

**Interfaces:**
- Consumes: `TakeoverController` (Task 5), `MenuBarController` (Task 6).
- Produces: `final class AppDelegate: NSObject, NSApplicationDelegate`.

- [ ] **Step 1: Write the delegate**

`Sources/ScreenHere/AppDelegate.swift`:

```swift
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let takeover = TakeoverController()
    private var menu: MenuBarController?
    private var didCompleteLaunch = false
    private let log = OSLog(subsystem: "com.screenhere.app", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance (e.g. `open -n`) asks the running one to reveal
        // its icon, then quits. Reopening the .app is handled below instead.
        if anotherInstanceIsRunning() {
            log("Second instance detected — forwarding show-icon request, then quitting.")
            DistributedNotificationCenter.default().postNotificationName(
                MenuBarController.showIconNotification, object: nil,
                options: [.deliverImmediately])
            NSApp.terminate(nil)
            return
        }

        // Before anything else: if a previous run died holding the system
        // shortcuts, give them back now.
        takeover.healAfterUncleanExit()

        let controller = MenuBarController(takeover: takeover)
        menu = controller
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showMenuBarIcon),
            name: MenuBarController.showIconNotification, object: nil)

        takeover.enable()
        if case .failed(let reason) = takeover.status {
            log("Takeover failed at launch: \(reason)")
        }
        didCompleteLaunch = true
    }

    /// The common recovery path: double-clicking the .app while it is already
    /// running activates the existing process instead of spawning a new one,
    /// so `applicationDidFinishLaunching` does not fire again.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard didCompleteLaunch else { return }
        guard let menu, !menu.isIconVisible else { return }
        log("Reopened while icon hidden — revealing for this session.")
        menu.unhideIcon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        if let menu, !menu.isIconVisible {
            log("Reopen event while icon hidden — revealing for this session.")
            menu.unhideIcon()
        }
        return true
    }

    /// Hand ⇧⌘3 back to macOS on the way out. This is the first of the four
    /// guards in the spec; the others cover the paths that never reach here.
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        takeover.disable()
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != myPID
        }
    }

    @objc private func showMenuBarIcon() {
        menu?.unhideIcon()
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
```

`Sources/ScreenHere/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; menu-bar only
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 2: Run the whole suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/ScreenHere/AppDelegate.swift Sources/ScreenHere/main.swift
git commit -m "feat: wire up the app lifecycle and restore shortcuts on quit"
```

- [ ] **Step 4: Assemble a runnable bundle for manual testing**

A bare SwiftPM binary has no `Info.plist`, so `LSUIElement` and the bundle
identifier would be missing and `SMAppService` would misbehave. Build a real
`.app` first:

```bash
swift build -c release -Xswiftc -target -Xswiftc arm64-apple-macos13.0
mkdir -p build/ScreenHere.app/Contents/MacOS
cp .build/release/ScreenHere build/ScreenHere.app/Contents/MacOS/ScreenHere
cp Resources/Info.plist build/ScreenHere.app/Contents/Info.plist
codesign --force --deep --sign - build/ScreenHere.app
open build/ScreenHere.app
```

- [ ] **Step 5: Verify by hand, then hand the shortcuts back**

Grant Screen Recording when prompted (the prompt names ScreenHere, since TCC
treats it as the responsible process for the `screencapture` child), then walk
this list. **If any step misbehaves, quit ScreenHere and confirm `⇧⌘3` works
again before debugging** — never leave the machine without a screenshot key.

1. Pointer on the **built-in** display, press `⇧⌘3` → the built-in screen lands in the clipboard. Paste to confirm.
2. Pointer on the **external** display, press `⇧⌘3` → the external screen lands in the clipboard.
3. Press `⌃⇧⌘3` on each display → same result, forced to the clipboard.
4. Open the menu: the status line reads "⇧⌘3 captures the screen under your pointer", and "Pointer is on: …" names the display the pointer was on when the menu opened.
5. Toggle "Capture the Screen Under the Pointer" off → `⇧⌘3` reverts to stock macOS behaviour (the external display). Toggle back on.
6. Click "Restore macOS Shortcuts" → same reversion, and the status line reads "Off — macOS handles ⇧⌘3".
7. Quit ScreenHere from the menu → `⇧⌘3` is stock macOS again.
8. Unclean-exit recovery: relaunch, then `killall -9 ScreenHere`. `⇧⌘3` is dead at this point — expected. Relaunch ScreenHere: `healAfterUncleanExit` restores the entries, then `enable()` re-takes them, and `⇧⌘3` captures the pointer display again. Quit, and confirm `⇧⌘3` is stock.
9. Confirm the shutter sound still plays, since `-p` uses the user's settings.

Record anything surprising in the commit message.

- [ ] **Step 6: Commit any fixes from manual testing**

```bash
git add -A
git commit -m "fix: address findings from the first end-to-end run"
```

---

### Task 8: Icon, packaging, docs, CI

**Files:**
- Create: `scripts/make-icon.swift`, `scripts/build-dmg.sh`, `README.md`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`

**Interfaces:**
- Consumes: the built product from Task 7.
- Produces: `build/ScreenHere.dmg`.

- [ ] **Step 1: Write the icon generator**

`scripts/make-icon.swift` — the menu-bar motif scaled up onto the violet squircle
PodFidelity uses, so the two apps read as a family:

```swift
#!/usr/bin/env swift
import AppKit

// Generates the ScreenHere app icon: a violet squircle carrying the same motif
// as the menu-bar glyph — two overlapping displays with a pointer knocked out
// of the near one. Renders the vector at every iconset size so small sizes stay
// crisp; the caller runs `iconutil` to produce the .icns.

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.iconset"

// (name, pixelSize)
let variants: [(String, Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024),
]

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.cgContext.interpolationQuality = .high

    // Everything below is authored on a 1024 grid and scaled to `size`.
    let f = size / 1024.0
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * f, y: y * f, width: w * f, height: h * f)
    }
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * f, y: y * f) }

    // --- background squircle (Apple grid: 824 content in 1024, radius ~185) ---
    let bg = NSBezierPath(roundedRect: R(100, 100, 824, 824), xRadius: 185 * f, yRadius: 185 * f)
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.13, blue: 0.55, alpha: 1),   // deep indigo (bottom)
        NSColor(srgbRed: 0.56, green: 0.31, blue: 0.96, alpha: 1),   // bright violet (top)
    ])!
    grad.draw(in: bg, angle: 90)

    let sheen = NSBezierPath(roundedRect: R(100, 540, 824, 384), xRadius: 185 * f, yRadius: 185 * f)
    NSColor(white: 1, alpha: 0.06).setFill()
    sheen.fill()

    let white = NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1)

    // --- far display: an outline frame, up and to the right ---
    let far = NSBezierPath()
    far.append(NSBezierPath(roundedRect: R(500, 520, 320, 230), xRadius: 26 * f, yRadius: 26 * f))
    far.append(NSBezierPath(roundedRect: R(534, 554, 252, 162), xRadius: 10 * f, yRadius: 10 * f))
    far.windingRule = .evenOdd
    NSColor(white: 1, alpha: 0.45).setFill()
    far.fill()

    // --- near display: solid, with the pointer punched out of it ---
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
    shadow.shadowBlurRadius = 30 * f
    shadow.shadowOffset = NSSize(width: 0, height: -12 * f)
    shadow.set()

    let near = NSBezierPath()
    near.append(NSBezierPath(roundedRect: R(210, 300, 400, 285), xRadius: 32 * f, yRadius: 32 * f))
    near.append(NSBezierPath(rect: R(370, 250, 80, 55)))                                  // stand
    near.append(NSBezierPath(roundedRect: R(320, 225, 180, 42), xRadius: 18 * f, yRadius: 18 * f))

    let pointer = NSBezierPath()
    pointer.move(to: P(330, 520))
    pointer.line(to: P(330, 330))
    pointer.line(to: P(382, 382))
    pointer.line(to: P(416, 314))
    pointer.line(to: P(458, 332))
    pointer.line(to: P(424, 400))
    pointer.line(to: P(496, 408))
    pointer.close()
    near.append(pointer)

    near.windingRule = .evenOdd     // the pointer becomes a hole onto the gradient
    white.setFill()
    near.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)

for (name, px) in variants {
    let rep = draw(CGFloat(px))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(name)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

print("wrote \(variants.count) images to \(outDir)")
```

- [ ] **Step 2: Write the DMG script**

`scripts/build-dmg.sh`: copy `../airpods_mic_fixer_reborn/scripts/build-dmg.sh`, then change `APP_NAME` and `EXECUTABLE` to `ScreenHere` and add the deployment-target flags to the build line:

```bash
swift build -c "$CONFIG" -Xswiftc -target -Xswiftc arm64-apple-macos13.0
```

- [ ] **Step 3: Run it**

Run: `bash scripts/build-dmg.sh`
Expected: `==> Done: build/ScreenHere.dmg`.

- [ ] **Step 4: Confirm the deployment target actually took**

Run: `otool -l build/ScreenHere.app/Contents/MacOS/ScreenHere | grep -A3 LC_BUILD_VERSION`
Expected: `minos 13.0`. Anything higher means the flags did not reach the compiler and LaunchServices will refuse the bundle on older systems.

- [ ] **Step 5: Write the README**

`README.md`, following PodFidelity's structure: centred banner, download badge, macOS/Swift/zero-dependency/MIT/CI badges, then these sections.

- **The problem** — `⇧⌘3` captures every display, and with the screenshot destination set to the clipboard only one image can fit, so macOS keeps the *main* display. If your main display is not the one you are looking at, you get the wrong screen every time.
- **The fix** — ScreenHere borrows `⇧⌘3` and `⌃⇧⌘3` and captures the display your pointer is on. Same shortcut, same destination, same folder, same sound.
- **How it works** — disables symbolic hotkeys 28 and 29, registers the same combinations, resolves the pointer's display, delegates to `screencapture -p -D<n>`.
- **Install** — download the DMG, drag to Applications, right-click → Open the first time (the build is ad-hoc signed, not notarized).
- **Getting your shortcut back** — the menu item, and the manual escape hatch for anyone whose app is gone:

  ```bash
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 28 '<dict><key>enabled</key><true/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>51</integer><integer>20</integer><integer>1179648</integer></array></dict></dict>' && /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  ```

  and the same for `29` with `1441792`.
- **Permissions** — Screen Recording, requested on first capture.
- **Build from source** — `swift test`, then `bash scripts/build-dmg.sh`.

- [ ] **Step 6: No CI — cut releases locally**

Deviation from this plan, decided during execution: **no GitHub Actions at all.**
GitHub runners have no access to the Developer ID certificate, and an ad-hoc
build silently costs every user their Screen Recording grant. `scripts/release.sh`
cuts the release locally instead, and refuses to run without a Developer ID
identity. `scripts/install.sh` builds, signs and installs into `/Applications`
in one step.

- [ ] **Step 7: Commit**

```bash
git add scripts README.md .github
git commit -m "chore: package as a DMG, document, and add CI"
```
