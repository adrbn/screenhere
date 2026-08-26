#!/usr/bin/env bash
# Cut a signed release.
#
#   ./scripts/release.sh 1.0.1
#
# Bumps the version, runs the tests, builds the DMG, tags, pushes, and publishes
# the GitHub release with the DMG attached.
#
# It refuses to run rather than ship something subtly broken: no Developer ID
# identity means an ad-hoc build, which costs every user a fresh Screen
# Recording grant, so that is a hard error rather than a warning.
#
# Notarization is optional here. Set NOTARY_PROFILE to a profile created with
# `xcrun notarytool store-credentials` to have the DMG notarized and stapled.
set -euo pipefail

VERSION="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
PLIST="Resources/Info.plist"
DMG="build/ScreenHere.dmg"

die() { echo "error: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- guardrails

[ -n "$VERSION" ] || die "usage: ./scripts/release.sh <version>   e.g. 1.0.1"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version must look like 1.2.3, got '$VERSION'"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || die "on branch '$BRANCH'; releases are cut from main"

[ -z "$(git status --porcelain)" ] \
    || die "working tree is dirty; commit or stash first"

git fetch origin main --quiet
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "local main differs from origin/main; push or pull first"

! git rev-parse "v$VERSION" >/dev/null 2>&1 \
    || die "tag v$VERSION already exists"

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
# This guard catches "you forgot to bump the version". On the very first
# release there is nothing to bump yet, so it would be a false positive.
if [ -n "$(git tag)" ]; then
    [ "$CURRENT" != "$VERSION" ] || die "$PLIST is already at $VERSION"
fi

security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
    || die "no Developer ID Application identity in the keychain — an ad-hoc build would force every user to re-grant Screen Recording"

if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notarization profile '$NOTARY_PROFILE' not found; create it with: xcrun notarytool store-credentials"
else
    echo "note: NOTARY_PROFILE unset — the DMG will be signed but not notarized,"
    echo "      so first-time downloaders get a Gatekeeper warning."
fi

command -v gh >/dev/null || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

echo "About to release v$VERSION (currently $CURRENT)."
# `|| true` so a closed stdin aborts with a message instead of exiting silently
# under `set -e`.
read -r -p "Continue? [y/N] " reply || true
[[ "${reply:-}" =~ ^[Yy]$ ]] || die "aborted"

# ---------------------------------------------------------------- build

echo "==> Running tests…"
swift test

echo "==> Bumping $PLIST to $VERSION…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

echo "==> Building and signing…"
NOTARY_PROFILE="$NOTARY_PROFILE" ./scripts/build-dmg.sh

# ---------------------------------------------------------------- publish

echo "==> Committing, tagging and pushing…"
git add "$PLIST"
if git diff --cached --quiet; then
    echo "    $PLIST already at $VERSION — nothing to commit."
else
    git commit -m "chore: release v$VERSION"
    git push origin main
fi
git tag -a "v$VERSION" -m "v$VERSION"
git push origin "v$VERSION"

echo "==> Publishing the GitHub release…"
gh release create "v$VERSION" "$DMG" --title "v$VERSION" --generate-notes

echo
echo "Released: $(gh release view "v$VERSION" --json url -q .url)"
echo "Edit the notes if the generated ones need a human pass."
