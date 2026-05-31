#!/usr/bin/env bash
# Ad-hoc sign with a stable identifier so Accessibility grant persists across
# rebuilds. The identifier — not the path — is what TCC uses to remember the
# Accessibility decision, so signing with the same `--identifier` keeps the
# grant intact across `swift build -c release` iterations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
[[ -f Package.swift ]] || { echo "expected Package.swift in $(pwd)"; exit 2; }

BIN=".build/release/wreaper"
[[ -f "$BIN" ]] || { echo "build first: swift build -c release"; exit 1; }

codesign \
    --sign - \
    --identifier com.user.windowless-reaper \
    --force \
    --preserve-metadata=entitlements,requirements \
    "$BIN"

echo "Signed $BIN with stable identifier com.user.windowless-reaper"
codesign -dv "$BIN" 2>&1 | grep -E "Identifier|Authority|Signature"
echo
echo "Verify before granting Accessibility:"
echo "  codesign --verify --strict --verbose=4 $BIN"
echo
echo "Grant Accessibility to the resolved absolute path:"
echo "  $(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
echo
echo "Or, after install:"
echo "  wreaper permissions path"
