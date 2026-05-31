#!/usr/bin/env bash
# Resolve packages, build, and run tests. Run from anywhere.
# Prerequisites (install manually via Brewfile): swiftlint swiftformat periphery fswatch xcbeautify coreutils jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
[[ -f Package.swift ]] || { echo "expected Package.swift in $(pwd)"; exit 2; }

# Verify the toolchain satisfies .swift-version.
required="$(cat .swift-version 2>/dev/null || echo 6.2)"
actual="$(swift --version | sed -n 's/.*Apple Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
if [[ -z "$actual" ]]; then
    echo "could not parse swift version from \`swift --version\`" >&2
    exit 2
fi
req_major="${required%%.*}"; req_minor="${required##*.}"
act_major="${actual%%.*}"; act_minor="${actual##*.}"
if (( act_major < req_major )) || { (( act_major == req_major )) && (( act_minor < req_minor )); }; then
    echo "swift $required+ required (found $actual)" >&2
    exit 2
fi

swift package resolve
gtimeout 90 swift build
gtimeout 90 swift test --parallel

echo
echo "dev-setup complete. Try: swift run wreaper --help"
