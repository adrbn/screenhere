# How ScreenHere works

The details behind each feature, for the curious and for anyone who wants to check what the app does to their Mac. None of it is needed to use ScreenHere: the [README](../README.md) covers that.

- [Taking over ⇧⌘3](#taking-over-3)
- [Giving the shortcut back](#giving-the-shortcut-back)
- [Capturing a window (beta)](#capturing-a-window-beta)
- [The capture preview](#the-capture-preview)
- [Copy text from the screen](#copy-text-from-the-screen)
- [Clipboard history](#clipboard-history)
- [Link previews (beta)](#link-previews-beta)
- [Install notes](#install-notes)
- [Uninstall](#uninstall)

## Taking over ⇧⌘3

macOS keeps its keyboard shortcuts in a preferences table called `AppleSymbolicHotKeys`. <kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd> is entry **28**, <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd> is entry **29**. An app-level hotkey always loses to a system one, so ScreenHere disables those two entries, asks the window server to reload the table, and registers the same combinations through Carbon's `RegisterEventHotKey`.

On each press it reads the pointer's global position, finds the display whose bounds contain it, converts that to the display's index in `CGGetActiveDisplayList`, and runs:

```
/usr/sbin/screencapture -p -D<index>     # ⇧⌘3  — your configured destination
/usr/sbin/screencapture -c -D<index>     # ⌃⇧⌘3 — forced to the clipboard
```

The display is worked out again on every press, so plugging in or unplugging a display never confuses it.

**It deliberately does not capture pixels itself.** Delegating to Apple's binary inherits the destination, folder, format and shutter sound for free, and keeps working when you change those settings later in the Screenshot app. Reimplementing that with ScreenCaptureKit would be several times the code for a worse imitation.

## Giving the shortcut back

Borrowing a system shortcut means the app owes you an exit. Four independent guards make sure you never end up with a dead <kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd>:

1. **On quit and on shutdown.** `applicationWillTerminate` restores both entries, and a `willPowerOff` observer does the same before the machine goes down, since logout does not reliably reach the former. Same for toggling the app off.
2. **On the next launch.** If a previous run died holding them, ScreenHere restores them before doing anything else, then takes them again cleanly.
3. **From the panel.** **Restore macOS Shortcuts** is always there, whatever state the app is in.
4. **Without the app at all.** See below.

Updates follow the same rule: the shortcut is handed back to macOS across the relaunch, so installing an update never leaves a dead key.

When ScreenHere replaces an entry it writes back the **complete** original dictionary with only `enabled` flipped. A naive `-dict-add 28 '{enabled = 0;}'` would drop the `parameters` array, and the shortcut would stay dead even after being re-enabled.

### Without the app

If you deleted ScreenHere while it held the shortcut, paste this into Terminal:

```bash
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 28 '<dict><key>enabled</key><true/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>51</integer><integer>20</integer><integer>1179648</integer></array></dict></dict>' && /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

The same command with `29` and `1441792` restores <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd>.

## Capturing a window (beta)

Turn on **Window** in the panel and ScreenHere can capture only the window under the pointer. It is off by default. Then <kbd>⇧</kbd><kbd>⌘</kbd><kbd>2</kbd> captures the window, and <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>2</kbd> sends it to the clipboard, as <kbd>⌃</kbd> does for the screen.

**Window shortcut** takes any other shortcut: click it, press the keys, or <kbd>Esc</kbd> to keep the one you had — as does closing the menu, or pressing the shortcut you already have. The arrow next to it goes back to <kbd>⇧</kbd><kbd>⌘</kbd><kbd>2</kbd>. A shortcut needs <kbd>⌘</kbd> or <kbd>⌥</kbd>, and leaves out <kbd>⌃</kbd>, which ScreenHere adds for the clipboard. The ones ScreenHere and macOS already use for screenshots are refused. While **Window** is on, the shortcut belongs to ScreenHere and no longer reaches the app in front. If another app registered it first, the tile says **Shortcut in use**. Keys are shown as your keyboard prints them, so a French keyboard reads <kbd>⇧</kbd><kbd>⌘</kbd><kbd>2</kbd> too.

To find the window, ScreenHere lists the windows on screen from front to back (`CGWindowListCopyWindowInfo`) and takes the first ordinary one under the pointer. It skips its own windows, invisible ones and anything under 40 points on a side, and looks through transparent overlays that cover a whole display, and through the pointer itself, which macOS sometimes draws in a small window of its own. Over the Dock, a menu or the menu bar, or with no window under the pointer, you get the display, as with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd>, and ScreenHere notes in the system log (layers and sizes, never titles) what was under the pointer. Then it runs:

```
/usr/sbin/screencapture -p -l <window id>     # your configured destination
/usr/sbin/screencapture -c -l <window id>     # with ⌃, the clipboard
```

As for the display, macOS's own binary keeps your destination, format and sound, and the window shadow follows your macOS setting.

## The capture preview

macOS shows a small preview after a screenshot, and puts it wherever it likes, which on a multi-display Mac is rarely the screen you just captured. There is no setting for that: the preview belongs to macOS's own capture UI, and its placement is not exposed.

So **Preview on Captured Screen** in the panel draws ScreenHere's own instead, in the corner of the display the capture came from. Click it to reveal the file in Finder, drag it out to drop the file into another app, flick it off to the right to dismiss it (with the pointer or with two fingers on the trackpad), or leave it, and it fades after a few seconds.

It covers **every** capture, not only the ones ScreenHere handles: <kbd>⇧</kbd><kbd>⌘</kbd><kbd>4</kbd>, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>5</kbd> and the Screenshot app get a preview too. They have to: switching macOS's preview off switches it off for them as well, and a region capture sent straight to the clipboard would otherwise leave no file, no preview and no sign it had worked.

> With the destination set to the clipboard there is no file to watch, so a capture is recognised by what lands on the pasteboard: a screenshot arrives as bare image data, while an image copied from a web page carries its markup and address along. That is a judgement rather than a certainty, so an image copied some other way may occasionally raise a preview.

> This is the one place ScreenHere changes a macOS setting, and it is the reason the option is off by default. Turning it on remembers your `show-thumbnail` value and disables macOS's preview so you do not get two; turning it off, quitting, or shutting down puts your value back, including the common case where the key was never set at all, which is restored by removing it rather than writing `true`.

## Copy text from the screen

Press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>7</kbd> and drag over the text you want. It is macOS's own crosshair, so <kbd>Space</kbd> picks a window and <kbd>Esc</kbd> cancels. The text is on your clipboard, with a short confirmation at the top of the screen. It is on by default and switches off from the panel.

macOS assigns <kbd>⇧</kbd><kbd>⌘</kbd><kbd>7</kbd> to *Save picture of the Touch Bar*, entry **181**, so ScreenHere borrows it exactly as it borrows <kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd> and hands it back the same ways. If another app also uses the combination (TextSniper does), macOS gives the key to whichever app registered first, and ScreenHere cannot always tell: switch it off in the other app.

Recognition runs on device with Vision's accurate engine, in a small reader process that stays loaded while the shortcut is on: about 20–50 MB and no CPU at rest. That is deliberate. Loading Vision's models in a fresh process can cost a Neural Engine compile of a minute or more on macOS 27, and a reader that stays up pays it once. If the reader is not ready, the fast engine answers instead, instantly but with more misreads. Keyboard symbols such as <kbd>⌘</kbd> and <kbd>⇧</kbd> are not in Vision's alphabet and come out garbled.

## Clipboard history

Switch on **Clipboard History** in the panel, then press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>8</kbd> anywhere: a list of the last 200 texts and pictures you copied (up to 100 MB of pictures) opens under the pointer, without taking focus from the app you are in. Type to filter, use the arrows to choose, <kbd>Return</kbd> to copy, <kbd>Esc</kbd> to close, then <kbd>⌘</kbd><kbd>V</kbd> as usual. **Clear History** empties it, from the panel or the list.

The history stays on your Mac, in `~/Library/Application Support/ScreenHere`, readable by your account only. Copies that password managers mark as concealed are never recorded. On macOS 15.4 and later, macOS asks before an app reads the clipboard in the background: choose **Always Allow**. Until it is allowed, the panel shows **Allow Clipboard Access…**, which opens the setting.

## Link previews (beta)

**Link Previews** (off by default) shows a copied link as its page's title and its site's icon. To get them, ScreenHere visits the link (when the list shows it, never when you copy it) the way a careful stranger would: no cookies, no saved passwords, tracking parameters left behind, the top megabyte of the page at most, and nothing at all on a Low Data Mode network. The site still sees a visit from your IP address, as it would if you opened the link. A firewall such as LuLu will ask about it the first time.

A visit could spend a link that signs you in or resets a password, so ScreenHere never visits one that looks private or single-use: addresses on your own network (including names that point there, and redirects that lead there), links that are not https, links with a port or a password in them, links carrying a token, code, key, signature or long random identifier, and sign-in, reset, confirmation, invitation and unsubscribe addresses (login.example.com included). Those rows show a lock instead of an icon. No filter catches every such link, which is why previews are off until you turn them on. Previews are kept next to the history, leave with the links they belong to, and are all deleted when you turn the setting off or clear the history.

## Install notes

**Install it in `/Applications`, not somewhere temporary.** The Screen Recording grant is keyed to the app's path as well as its code identity, so an app that moves has to be authorised again.

Builds are signed with Developer ID and notarized, so the grant survives updates: you authorise ScreenHere once, not again after every release. Updates are checked once a day and install in place through [Sparkle](https://sparkle-project.org).

**Launch at login matters.** ScreenHere leaves the system shortcut disabled while it holds it, so a Mac that restarts without it running would have <kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd> doing nothing until you reopen the app. ScreenHere hands the shortcut back when the Mac shuts down, so you are never stranded, but launching at login is what keeps it working.

**Hiding the menu-bar icon.** **Hide Menu Bar Icon** removes the icon; the app keeps running and the shortcuts keep working. Opening ScreenHere again from `/Applications` or Spotlight brings the icon back for good.

## Uninstall

1. Open the panel and click **Restore macOS Shortcuts**. This is the step that matters: it hands <kbd>⇧</kbd><kbd>⌘</kbd><kbd>3</kbd> back to macOS.
2. Quit ScreenHere and drag it from `/Applications` to the Trash.

If you deleted the app without step 1, the Terminal command under [Without the app](#without-the-app) restores the shortcut.

ScreenHere stores a few preferences and, if you switched it on, the clipboard history: `defaults delete com.screenhere.app` removes the preferences, including Sparkle's update schedule, and `rm -rf ~/Library/Application\ Support/ScreenHere` removes the history.
