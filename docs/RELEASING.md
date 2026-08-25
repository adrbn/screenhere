# Releasing

Maintainer notes. Nothing here is needed to use or build ScreenHere — see the
[README](../README.md) for that.

## Cutting a release

```bash
./scripts/release.sh 1.0.1
```

That bumps the version, runs the tests, builds, signs, tags, pushes and publishes the GitHub release with the DMG attached. It refuses to run on a dirty tree, off `main`, behind `origin`, on an existing tag, or without a Developer ID identity — since an ad-hoc build would silently cost every user their Screen Recording grant.

Releases are cut locally rather than in CI, because GitHub runners have no access to the certificate. To notarize as well, create the profile once and pass it in:

```bash
xcrun notarytool store-credentials screenhere --apple-id <apple-id> --team-id <team-id>
NOTARY_PROFILE=screenhere ./scripts/release.sh 1.0.1
```

The app icon is generated from `scripts/make-icon.swift`.


## Why not CI

GitHub runners have no access to the Developer ID certificate, and an ad-hoc
build silently costs every user their Screen Recording grant — the toggle in
System Settings keeps looking enabled while `tccd` denies every capture. So
releases are cut locally, and `release.sh` refuses to run without an identity.
