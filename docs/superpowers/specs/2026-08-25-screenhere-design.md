# ScreenHere — Design

**Date:** 2026-08-25
**Status:** Approved · not yet implemented

## 1. Problem

On a multi-display Mac, `⇧⌘3` ("Save picture of screen") does not capture the screen you are
looking at. It captures every display — and when the user's screenshot destination is the
**clipboard**, only one image can fit there, so macOS keeps the *main* display and silently
discards the other.

On this machine the main display is the external MSI MD271UL, so every `⇧⌘3` returns the
external screen even when the pointer, the window, and the user's attention are all on the
built-in one. The only workaround today is `⇧⌘5`, which requires clicking the target display
by hand every time.

Verified root cause (`defaults read com.apple.screencapture`):

```
target-screenshot = clipboard      # one image max → macOS must pick a display
style             = selection
location-last     = ~/Desktop
```

**Goal:** `⇧⌘3` captures the display the pointer is on. No new shortcut to learn, no change in
where captures end up.

## 2. Approach (approved)

**Borrow the system shortcut; delegate the capture.**

ScreenHere disables the macOS symbolic hotkeys for `⇧⌘3` and `⌃⇧⌘3`, registers the same two
combinations for itself, and on each press resolves the display under the pointer and runs the
system `screencapture` binary scoped to that display.

The capture itself is **not** reimplemented. `screencapture -p` reuses the user's own macOS
screenshot settings — destination, file location, format, shutter sound — so behaviour stays
native and stays correct if the user later changes those settings in System Settings.

### Rejected alternatives

- **`CGEventTap` swallowing `⇧⌘3` before the system sees it.** Leaves system preferences
  untouched, but needs Accessibility permission, taps get disarmed by the input watchdog, and
  winning the race against a symbolic hotkey is not contractual.
- **Post-processing.** Let `⇧⌘3` fire normally, then repair the result. Impossible with
  `target-screenshot = clipboard`: only one image ever arrives, and the wrong one.

### Findings that validate the approach (probed on macOS 27.0, build 26A5378n)

| Question | Result |
|---|---|
| Is `⇧⌘3` a disableable symbolic hotkey? | Yes — SHK **28** (`⇧⌘3`) and **29** (`⌃⇧⌘3`), both `enabled = true`, parameters `[51, 20, 1179648]` / `[51, 20, 1441792]` |
| Can the change apply without logout? | `…/SystemAdministration.framework/Resources/activateSettings` still present — **to confirm at implementation time** |
| What does `-D<n>` index? | 1-based position in `CGGetActiveDisplayList` order. `-D1` → MSI 5120×2880, `-D2` → built-in 3360×2100 |
| Does `-p` honour `-D`? | **Yes.** `-p -D2` produced a 3360×2100 image routed to the clipboard per the user's settings |
| Does the floating thumbnail appear? | No, when `-p` is launched from a CLI process. Immaterial here (clipboard destination); `-u` is the lever if it is ever wanted |

## 3. Scope

### In scope

- Take over `⇧⌘3` (save/route per user settings) and `⌃⇧⌘3` (force clipboard).
- Resolve the display under the pointer and capture only that display.
- Menu-bar UI: status line, enable/disable toggle, live "current screen" readout, restore-macOS-
  shortcuts, Launch at Login, Hide Menu Bar Icon, Check for Updates, GitHub link, Quit.
- Restore the macOS shortcuts on disable, on quit, and after an unclean exit.
- Unsigned DMG distribution, open source (MIT), GitHub Releases + CI.

### Non-goals

- `⇧⌘4` (its crosshair already moves freely between displays) and `⇧⌘5`.
- Annotation, region selection, window selection, video recording, cloud upload.
- Reimplementing the floating thumbnail or the screenshot editor.
- A custom, user-configurable shortcut. The whole point is that the existing one works.

## 4. Architecture

Single SwiftPM executable, zero dependencies, `LSUIElement` agent — same shape as PodFidelity.

| File | Responsibility |
|---|---|
| `main.swift` | `.accessory` activation policy, `AppDelegate` wiring |
| `AppDelegate.swift` | Lifecycle; restores system shortcuts on `applicationWillTerminate` |
| `CursorDisplay.swift` | Pointer position → `CGDirectDisplayID` → `-D` index. Pure, testable |
| `SymbolicHotkeys.swift` | Read / disable / restore SHK 28 & 29; invoke `activateSettings -u` |
| `HotkeyRegistrar.swift` | Carbon `RegisterEventHotKey` for `⇧⌘3` and `⌃⇧⌘3` |
| `CaptureRunner.swift` | Spawn `/usr/sbin/screencapture` with the resolved display index |
| `MenuBarController.swift` | `NSStatusItem` + `NSMenu`, rebuilt on open |
| `MenuBarIcon.swift` | Code-drawn template glyph: two overlapping displays, pointer on the near one |
| `LoginItem.swift` | `SMAppService` login-item toggle |
| `UpdateChecker.swift` | GitHub Releases version check (ported from PodFidelity) |

### Data flow

```
⇧⌘3 pressed
  → HotkeyRegistrar fires
  → CursorDisplay: CGEvent(source: nil)?.location          (global, top-left origin)
                   → CGGetDisplaysWithPoint                (fallback: CGMainDisplayID)
                   → index in CGGetActiveDisplayList + 1
  → CaptureRunner: /usr/sbin/screencapture -p -D<index>    (⌃⇧⌘3 → -c -D<index>)
  → macOS applies the user's own destination settings
```

### Enable / disable lifecycle

`SymbolicHotkeys` never writes a partial dictionary. It reads the **complete** entry for 28 and
29, stores a verbatim copy in ScreenHere's own preferences, then writes the same dictionary back
with `enabled = false`. Restoring writes the stored original. This preserves the `value ▸
parameters` array, which a naive `defaults write … -dict-add 28 '{enabled = 0;}'` would destroy.

Writes go through `/usr/bin/defaults` rather than `CFPreferences`, to avoid `cfprefsd` caching
surprises on a domain owned by the system.

## 5. Failure modes

**The one that matters: a crash leaves `⇧⌘3` disabled and the user with no screenshot at all.**
Four guards, in order of who catches it:

1. `applicationWillTerminate` restores on a clean quit and on the disable toggle.
2. At launch, if ScreenHere's preferences carry a "we disabled these" flag but the hotkeys are
   not currently ours to hold, the originals are restored before anything else runs.
3. **Restore macOS Shortcuts** is a permanent menu item — never hidden behind the toggle state.
4. The README documents the one-line `defaults` command to restore by hand without the app.

Other cases:

| Case | Behaviour |
|---|---|
| Single display | Resolves to that display; behaviour identical to stock macOS |
| Pointer in no display's bounds | Fall back to `CGMainDisplayID()` |
| Mirrored displays | `CGGetDisplaysWithPoint` returns the mirror set; take the first, which is the one `screencapture` addresses |
| Display hot-plugged between presses | Index is recomputed on every press, never cached |
| Screen Recording permission not yet granted | macOS prompts on the first capture; the menu status line reflects the denied state and links to System Settings |
| `activateSettings -u` unavailable | Change still lands, takes effect at next login; menu warns |

## 6. Testing

Pure-logic unit tests only — no test performs a real screen capture.

- `CursorDisplayTests`: pointer on the secondary display; on the primary; on a boundary pixel;
  outside every display; single-display setup; index recomputed after a simulated topology change.
- `SymbolicHotkeysTests`: parse a real SHK plist fixture; round-trip disable → restore yields a
  byte-identical dictionary; a partial/corrupt entry does not clobber the original.
- `MenuBarControllerTests`: menu item set and states for enabled / disabled / permission-denied.

## 7. Distribution

`scripts/build-dmg.sh` adapted from PodFidelity: SwiftPM release build, `.app` assembly,
ad-hoc signature, DMG. `-target arm64-apple-macos13.0` so the binary's `minos` stays below the
running OS — a Swift 6.4 toolchain otherwise stamps `macosx27.0`, which LaunchServices refuses
with `kLSIncompatibleSystemVersionErr (-10825)` on older systems. UI strings in English, matching
PodFidelity and Haze. MIT. GitHub Actions for CI and releases.
