#!/usr/bin/env bash
# pre-commit.sh — run all required checks before committing.
#
# Wire into git (one-time setup):
#   ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
#
# Or call manually:
#   scripts/pre-commit.sh
#
# Or from an existing hook:
#
# if [ ! -x "scripts/pre-commit.sh" ]; then
#     echo "Missing executable scripts/pre-commit.sh" >&2
#     exit 1
# fi
#
# ./scripts/pre-commit.sh

set -euo pipefail

resolve_script_path() {
    local source_dir=""
    local source_path="$1"
    while [ -L "${source_path}" ]; do
        source_dir="$(cd "$(dirname "${source_path}")" && pwd)"
        source_path="$(readlink "${source_path}")"
        [[ "${source_path}" != /* ]] && source_path="${source_dir}/${source_path}"
    done
    source_dir="$(cd "$(dirname "${source_path}")" && pwd)"
    printf '%s\n' "${source_dir}/$(basename "${source_path}")"
}

REAL_SCRIPT="$(resolve_script_path "$0")"
SCRIPT_DIR="$(cd "$(dirname "${REAL_SCRIPT}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

run() {
    echo "==> $*"
    "$@"
}

echo "==> Running windowless_reaper pre-commit checks..."

run swiftformat --lint .
run swiftlint --strict
run gtimeout 30 swift test --parallel

# Build with tests first so periphery can see test-target references.
run swift build --build-tests -Xswiftc -index-store-path -Xswiftc .build/index/store
run periphery scan --strict

# Reject additions of @unchecked Sendable / nonisolated(unsafe) without an inline justification comment.
unsafe_additions=$(git diff HEAD -U0 -- '*.swift' \
    | grep -E '^\+[^+]' \
    | grep -E '@unchecked Sendable|nonisolated\(unsafe\)' \
    | grep -vE '//' || true)
if [[ -n "${unsafe_additions}" ]]; then
    echo "==> FAIL: new @unchecked Sendable / nonisolated(unsafe) without an inline comment:" >&2
    echo "${unsafe_additions}" >&2
    exit 1
fi

echo "==> All checks passed."
echo "==> Reminder: if CLI output changed, update Tests/WindowlessReaperCoreTests/__Snapshots__/"
