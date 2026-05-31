#!/usr/bin/env bash
# Dev build with the live git version + commit stamped into --version.
#
# A plain `swift build` reports the committed placeholder (0.0.0-dev). This
# wrapper stamps BuildInfo.swift from `git describe` + the short HEAD hash,
# builds, then restores the placeholder on exit so the working tree is left
# clean. Extra args pass through to `swift build`:
#
#   scripts/dev-build.sh              # debug
#   scripts/dev-build.sh -c release   # release
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Restore the committed placeholder regardless of how we exit, so a stamped
# BuildInfo.swift never lingers in the working tree.
restore_build_info() { git checkout -- Sources/wreaper/BuildInfo.swift 2>/dev/null || true; }
trap restore_build_info EXIT

# Tag if we have one (e.g. v1.2.0-3-gabc123), else the short hash. `--dirty`
# flags uncommitted changes. stamp-version.sh validates the strings.
VERSION="$(git describe --tags --always --dirty)"
COMMIT="$(git rev-parse --short=12 HEAD)"

scripts/stamp-version.sh "$VERSION" "$COMMIT"
swift build "$@"
