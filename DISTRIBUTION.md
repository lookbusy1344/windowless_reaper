# Distribution

Two modes are supported:

1. **Local dev** — ad-hoc signature, stable identifier so the Accessibility
   grant survives rebuilds. `scripts/sign.sh` covers this; no Apple Developer
   account required.
2. **Signed release** — Developer-ID signed and notarised binary, suitable
   for handing to users outside the dev machine. `scripts/release.sh` covers
   this. Requires an Apple Developer account.

This document covers mode 2. Mode 1 is just `scripts/sign.sh`.

## Prerequisites

| Tool | Source | Notes |
|---|---|---|
| `codesign` | Xcode Command Line Tools | already required |
| `notarytool` | Xcode Command Line Tools | Apple's notarisation client |
| `xcrun stapler` | Xcode Command Line Tools | staples notarisation ticket |

No third-party tools. No `xcodebuild`.

## Required secrets

Values come from environment variables — **never** committed to the repo. The
release script exits with a clear error if any are missing.

| Env var | What it is | Where to get it |
|---|---|---|
| `WREAPER_TEAM_ID` | Apple Team ID (10-char alphanumeric) | developer.apple.com → Membership |
| `WREAPER_SIGNING_IDENTITY` | Common name of the Developer ID Application certificate, e.g. `Developer ID Application: Jane Smith (TEAMID12345)` | `security find-identity -v -p codesigning` |
| `WREAPER_NOTARY_PROFILE` | Name of a `notarytool store-credentials` keychain profile | `xcrun notarytool store-credentials WREAPER_NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>` |

The notary profile stores the Apple ID, team ID, and app-specific password in
the login keychain so they never appear on the command line or in CI logs.
Generate the app-specific password at appleid.apple.com (Sign-In and Security
→ App-Specific Passwords).

## Release flow

`scripts/release.sh <version>` performs:

1. `git diff --quiet` — refuses to release a dirty tree.
2. `swift test --parallel` — refuses to release if tests fail.
3. `swift build -c release` — builds `.build/release/wreaper`.
4. `codesign --options runtime --timestamp --sign "$WREAPER_SIGNING_IDENTITY"` —
   Developer-ID signs with the hardened runtime.
5. Zip the binary into `.build/release/wreaper-<version>.zip`.
6. `xcrun notarytool submit --keychain-profile $WREAPER_NOTARY_PROFILE --wait` —
   uploads to Apple, waits for the verdict.
7. `xcrun stapler staple` — attaches the ticket so the binary verifies offline.
8. `git tag v<version>` — only on success.

The script never pushes the tag. Pushing is a manual step.

## Verifying a released binary

```bash
codesign -dvv .build/release/wreaper
spctl -a -t install -vv .build/release/wreaper
xcrun stapler validate .build/release/wreaper
```

All three should succeed before handing the binary to anyone.

## CI

The GitHub Actions workflow (`.github/workflows/ci.yml`) does **not** sign or
notarise — it only verifies the build/test/lint gates. Releases are cut from
a developer machine where the signing identity and notary profile are
available; the workflow gates merge but not publication.
