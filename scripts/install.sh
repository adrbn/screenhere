#!/usr/bin/env bash
# Build, sign, and install into /Applications, then relaunch.
#
#   ./scripts/install.sh
#
# /Applications matters as much as the signature: the Screen Recording grant is
# keyed to the app's path as well as its code identity, so running the app from
# build/ (which is wiped by every build) costs a fresh authorisation each time.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-dmg.sh

echo "==> Installing to /Applications..."
osascript -e 'tell application "ScreenHere" to quit' 2>/dev/null || pkill -x ScreenHere || true
while pgrep -x ScreenHere >/dev/null; do :; done

rm -rf /Applications/ScreenHere.app
cp -R "build/ScreenHere.app" /Applications/ScreenHere.app

echo "==> Launching..."
open /Applications/ScreenHere.app
echo "==> Installed. ⇧⌘3 now captures the screen under your pointer."
