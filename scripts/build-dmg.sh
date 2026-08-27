#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ScreenHere"
EXECUTABLE="ScreenHere"
CONFIG="release"
OUT="build"

# Signing identity. Auto-detected from the keychain when present; override with
# SIGN_IDENTITY=... to pick a specific one. Falls back to ad-hoc so the build
# still works on machines without the certificate (contributors, fresh clones).
if [ -z "${SIGN_IDENTITY:-}" ]; then
    CANDIDATES=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | sed -E 's/.*"(.*)".*/\1/')
    COUNT=$(printf '%s' "$CANDIDATES" | grep -c . || true)
    if [ "$COUNT" -gt 1 ]; then
        # Picking arbitrarily could ship a release signed by a certificate that
        # is about to expire, or one you meant to retire. Make the choice explicit.
        echo "error: several Developer ID Application identities in the keychain:" >&2
        printf '  %s\n' $CANDIDATES >&2
        echo "Set SIGN_IDENTITY to the one you want." >&2
        exit 1
    fi
    SIGN_IDENTITY="$CANDIDATES"
fi

# Optional notarization: set NOTARY_PROFILE to a profile created once with
#   xcrun notarytool store-credentials <name> --apple-id ... --team-id ... --password ...
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "==> Generating the app icon..."
swift scripts/make-icon.swift Resources/AppIcon.iconset
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

echo "==> Building ($CONFIG)..."
# Pin the deployment target: a current Swift toolchain otherwise stamps the
# running OS version into LC_BUILD_VERSION, and LaunchServices then refuses the
# bundle on older systems with kLSIncompatibleSystemVersionErr (-10825).
swift build -c "$CONFIG" -Xswiftc -target -Xswiftc arm64-apple-macos13.0

BIN=".build/${CONFIG}/${EXECUTABLE}"
APP_DIR="${OUT}/${APP_NAME}.app"

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# SwiftPM links against Sparkle but does not assemble app bundles, so the
# framework has to be embedded by hand. The executable finds it through the
# @executable_path/../Frameworks rpath set in Package.swift; without this the
# app dies at launch with "Library not loaded: @rpath/Sparkle.framework".
# ditto rather than cp -R: the bundle relies on its Versions/Current symlinks.
SPARKLE_SRC=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos-arm64*" | head -1)
[ -n "$SPARKLE_SRC" ] || { echo "error: Sparkle.framework not found in .build/artifacts" >&2; exit 1; }
mkdir -p "${APP_DIR}/Contents/Frameworks"
ditto "$SPARKLE_SRC" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
echo "==> Embedded $(basename "$SPARKLE_SRC")"

# Why the identity matters beyond Gatekeeper: macOS keys the Screen Recording
# (TCC) grant to the app's code identity. An ad-hoc signature has no stable
# identity — its designated requirement is the cdhash, which changes on every
# build, so the user must re-authorise the app after each update. Worse, the
# Settings toggle keeps *looking* enabled while tccd quietly denies every
# capture. A Developer ID signature pins the requirement to the team, and the
# grant survives updates.
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing with: ${SIGN_IDENTITY}"
    # Deepest-first, because Sparkle's helpers keep the signature they were
    # published with: Apple rejects them at notarization, and Sparkle refuses
    # to launch its own installer when Autoupdate carries a different identity
    # from the app. The script seals the app last.
    ./scripts/sign_sparkle.sh "$APP_DIR" "$SIGN_IDENTITY"
else
    echo "==> WARNING: no Developer ID Application identity found — ad-hoc signing."
    echo "    Gatekeeper will warn on download, and users will have to re-grant"
    echo "    Screen Recording after every update."
    codesign --force --sign - "$APP_DIR"
fi

codesign --verify --strict --verbose "$APP_DIR"
echo "==> Designated requirement (what TCC remembers):"
codesign -d --requirements - "$APP_DIR" 2>&1 | tail -1

# Notarize and staple the .app itself, before it goes into the disk image.
# Stapling only the DMG leaves the app ticketless once dragged to /Applications,
# forcing Gatekeeper to ask Apple online at first launch — which fails offline.
if [ -n "$NOTARY_PROFILE" ]; then
    ZIP="${OUT}/${EXECUTABLE}-app.zip"
    echo "==> Notarizing the app..."
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    rm -f "$ZIP"
fi

DMG="${OUT}/${EXECUTABLE}.dmg"
echo "==> Creating ${DMG}..."
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG"

# The disk image needs its own signature, and it must be applied *before*
# notarization — signing afterwards would invalidate the stapled ticket.
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing the disk image..."
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing (this waits on Apple, usually a few minutes)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling..."
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "==> Gatekeeper verdict (this is what a downloader gets):"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "==> Skipping notarization (NOTARY_PROFILE unset)."
fi

# Sparkle installs from a zip, not from a disk image.
ZIP="${OUT}/${EXECUTABLE}.zip"
echo "==> Creating ${ZIP} (the archive Sparkle installs from)..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

echo "==> Done: $DMG and $ZIP"
