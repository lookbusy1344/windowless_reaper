#!/usr/bin/env bash
# pre-commit.sh — run all required checks before committing.
#
# Works in jj and plain Git checkouts.
#
# jj: no commit hooks, so run it directly before `jj commit`, `jj describe`
# (finalising) and `jj squash`. It checks the files changed in `@`.
#
# Git: wire in as a hook (one-time setup); it checks the staged files:
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

# GUI and hook launches omit the Homebrew paths.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

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

# A Git hook sets GIT_INDEX_FILE; in that case check the Git index, not jj.
use_jj() {
    [[ -z "${GIT_INDEX_FILE:-}" ]] && jj --ignore-working-copy root > /dev/null 2>&1
}

changed_files() {
    if use_jj; then
        jj diff --name-only -r @ --no-pager
    else
        git diff --cached --name-only
    fi
}

# Swift sources, plus the tool and package config the checks depend on.
readonly SWIFT_CHECK_PATTERN='(\.swift|(^|/)\.swiftformat|(^|/)\.swiftlint\.yml|(^|/)\.periphery\.yml|(^|/)Package\.resolved)$'

changed_swift_files() {
    changed_files | { grep -E "${SWIFT_CHECK_PATTERN}" || true; }
}

swift_diff_no_context() {
    if use_jj; then
        jj diff --git --context 0 -r @ --no-pager -- 'glob:"**/*.swift"'
    else
        git diff --cached -U0 -- '*.swift'
    fi
}

swift_staged=$(changed_swift_files)

if [[ -n "${swift_staged}" ]]; then
    run swiftformat --lint .
    run swiftlint --strict

    # Build tests with index store populated so periphery can see test-target references,
    # then run the suite.
    run swift build --build-tests --enable-index-store
    run gtimeout 30 swift test --parallel
    run periphery scan --strict

    # Reject additions of @unchecked Sendable / nonisolated(unsafe) without an inline justification comment.
    unsafe_additions=$(swift_diff_no_context \
        | grep -E '^\+[^+]' \
        | grep -E '@unchecked Sendable|nonisolated\(unsafe\)' \
        | grep -vE '//' || true)
    if [[ -n "${unsafe_additions}" ]]; then
        echo "==> FAIL: new @unchecked Sendable / nonisolated(unsafe) without an inline comment:" >&2
        echo "${unsafe_additions}" >&2
        exit 1
    fi
else
    echo "==> No Swift sources or tool config changed — skipping Swift checks."
fi

echo "==> All checks passed."
echo "==> Reminder: if CLI output changed, update Tests/WindowlessReaperCoreTests/__Snapshots__/"
