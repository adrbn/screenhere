#!/bin/bash
# Redraws the README pictures in docs/assets from the app's own views, with
# posed data: nothing is read from the clipboard or captured from the screen.
# The renderer is the active app for a moment, so its switches draw in colour.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
BIN=$(swift build --show-bin-path)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -F "$BIN" -framework Sparkle -Xlinker -rpath -Xlinker "$BIN" \
    $(ls Sources/ScreenHere/*.swift | grep -v '/Entry.swift$') scripts/readme-shots.swift \
    -o "$WORK/readme-shots"
"$WORK/readme-shots" "$WORK"
"$WORK/readme-shots" "$WORK" button

for picture in "$WORK"/*.png; do
    if command -v pngquant >/dev/null; then
        pngquant --quality 85-98 --speed 1 --force --output "docs/assets/$(basename "$picture")" "$picture"
    else
        cp "$picture" docs/assets/
    fi
done
