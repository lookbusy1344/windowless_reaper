#!/usr/bin/env bash
# Build, sign, notarise, and tag a release of wreaper.
# See DISTRIBUTION.md for prerequisites and required env vars.
#
# Flags:
#   --dry-run   Run every preflight gate (tests, release build, hash check,
#               version-tag check) without requiring Apple credentials or
#               touching codesign/notarytool. Safe on a developer machine.
#               Exits non-zero if any preflight gate fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/windowless-reaper-clang-module-cache"
mkdir -p "$MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH"

usage() {
    echo "usage: scripts/release.sh [--dry-run] <version>" >&2
    echo "       version must look like 0.2.0 (no leading v)" >&2
    exit 2
}

DRY_RUN=0
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"
[[ $# -eq 1 ]] || usage
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || {
    echo "release.sh: version '$VERSION' is not semver" >&2
    exit 2
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "release.sh: missing required env var \$$name (see DISTRIBUTION.md)" >&2
        exit 2
    fi
}

[[ -f Package.swift ]] || { echo "release.sh: expected Package.swift in $(pwd)" >&2; exit 2; }

# Preflight: every check that does NOT need Apple credentials. These run in
# both real and dry-run mode and must all pass before we touch codesign/
# notarytool or the git tag.
preflight() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "release.sh: working tree is dirty — commit or stash first" >&2
        exit 1
    fi

    local tag="v$VERSION"
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "release.sh: tag $tag already exists" >&2
        exit 1
    fi

    echo ">> swiftformat --lint"
    swiftformat --lint .
    echo ">> swiftlint --strict --no-cache"
    swiftlint --strict --no-cache
    echo ">> running tests"
    gtimeout 120 swift test --parallel --disable-sandbox
    echo ">> building release binary"
    swift build -c release --disable-sandbox
    [[ -f .build/release/wreaper ]] || {
        echo "release.sh: .build/release/wreaper not produced" >&2
        exit 1
    }
}

preflight

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "dry-run: preflight gates passed. Skipping codesign / notarytool / tag."
    echo "binary:  $(pwd)/.build/release/wreaper"
    echo "version: $VERSION"
    exit 0
fi

# Real release path — now we need credentials.
require_env WREAPER_TEAM_ID
require_env WREAPER_SIGNING_IDENTITY
require_env WREAPER_NOTARY_PROFILE

TAG="v$VERSION"
BIN=".build/release/wreaper"

echo ">> Developer-ID signing"
codesign \
    --sign "$WREAPER_SIGNING_IDENTITY" \
    --identifier com.user.windowless-reaper \
    --options runtime \
    --timestamp \
    --force \
    "$BIN"
codesign --verify --strict --verbose=4 "$BIN"
codesign -dvv "$BIN"

ZIP=".build/release/wreaper-${VERSION}.zip"
rm -f "$ZIP"
echo ">> zipping for notarisation: $ZIP"
ditto -c -k --keepParent "$BIN" "$ZIP"

echo ">> submitting to notary service"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$WREAPER_NOTARY_PROFILE" \
    --team-id "$WREAPER_TEAM_ID" \
    --wait

echo ">> stapling ticket"
xcrun stapler staple "$BIN"
xcrun stapler validate "$BIN"

echo ">> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$BIN" || {
    echo "release.sh: spctl assessment failed — refusing to tag" >&2
    exit 1
}

echo ">> tagging $TAG (not pushed)"
git tag -a "$TAG" -m "Release $VERSION"

echo
echo "Released $TAG."
echo "Binary: $BIN"
echo "Zip:    $ZIP"
echo "Next:   git push origin $TAG  (manual, per CLAUDE.md no-push rule)"
