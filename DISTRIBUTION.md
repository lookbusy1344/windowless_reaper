# Distribution

Three modes are supported:

1. **Local dev** — ad-hoc signature, stable identifier so the Accessibility
   grant survives rebuilds. `scripts/sign.sh` covers this; no Apple Developer
   account required.
2. **Ad-hoc tag release (CI)** — push a `v*` tag and the
   `.github/workflows/release.yml` workflow builds, ad-hoc signs, and publishes
   a GitHub Release. No Apple Developer account, no secrets. See below.
3. **Developer-ID release** — Developer-ID signed and notarised binary,
   suitable for handing to users outside the dev machine. `scripts/release.sh`
   covers this. Requires an Apple Developer account.

This document's "Required secrets" / "Release flow" sections cover mode 3.
Mode 1 is just `scripts/sign.sh`.

## Version stamping

`--version` reports `<tag> (<short-commit>)`, e.g. `1.2.0 (3f29b14f08eb)`.
`Sources/wreaper/BuildInfo.swift` is committed with dev placeholders
(`0.0.0-dev (unknown)`); `scripts/stamp-version.sh <version>` overwrites it
with the tag and `git rev-parse --short HEAD`. Both the CI workflow and
`scripts/release.sh` stamp before `swift build -c release`, so a released
binary self-reports the tag that produced it. A plain `swift build` does **not**
stamp — dev builds report the placeholder.

## Ad-hoc tag release (mode 2)

```bash
git tag -a v1.2.0 -m "Release 1.2.0"
git push origin v1.2.0      # triggers .github/workflows/release.yml
```

The workflow stamps the version, builds release, ad-hoc signs via
`scripts/sign.sh`, and attaches the raw `wreaper` binary, a
`wreaper-<version>-macos.tar.gz`, and `SHA256SUMS` to a GitHub Release.

Ad-hoc signing carries no Developer-ID identity. For the target audience this
is fine: a `curl` download has no quarantine flag and runs as is. A browser
download is quarantined and needs one `xattr -dr com.apple.quarantine ./wreaper`
before first run. Accessibility is granted manually either way (mode 3's
notarisation does not change that). Use mode 3 only if you need Gatekeeper to
accept a browser-downloaded binary without the `xattr` step.

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

`.github/workflows/ci.yml` does **not** sign or notarise — it only verifies the
build/test/lint gates on every push/PR.

`.github/workflows/release.yml` runs on `v*` tags and publishes an **ad-hoc**
signed GitHub Release (mode 2). It needs no secrets. Developer-ID +
notarisation (mode 3) is **not** run in CI — it requires the signing identity
and notary profile from a developer machine, so `scripts/release.sh` is cut
locally.
