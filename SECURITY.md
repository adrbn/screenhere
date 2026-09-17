# Security

## Supported versions

Only the latest release gets fixes. ScreenHere updates itself, so that is the version almost everyone runs.

## Reporting a vulnerability

Please report it privately: open the repository's **Security** tab and click **Report a vulnerability**. Do not open a public issue for it.

Useful things to include: what an attacker could do, the steps to reproduce, your macOS version and the ScreenHere version.

## What counts

ScreenHere borrows system shortcuts, keeps a clipboard history on disk, can fetch link previews, and updates itself through Sparkle. Anything that lets someone read that history, run code through the app or its updates, reach your local network through a link preview, or leave your Mac without its screenshot shortcuts is in scope.
