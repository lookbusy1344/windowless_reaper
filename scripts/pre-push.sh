#!/usr/bin/env bash
# pre-push.sh — format, lint, build and test unpushed jj revisions.
#
# In a plain Git checkout there are no revisions to select: it runs the same
# checks on the working tree. If swiftformat finds violations it reformats the
# tree and fails, so the fixes get committed before the push. --full makes no
# difference there. Install as a Git hook:
#   ln -sf ../../scripts/pre-push.sh .git/hooks/pre-push
#
# Default: the tip only (the newest non-empty mutable revision in ::@).
# --full: every non-empty mutable revision in ::@, each in its own checkout
# via `jj run` (cold build per revision).
#
# Run before `jj git push` or moving a shared bookmark. The checks match CI
# (.github/workflows/ci.yml).

set -euo pipefail

# GUI and hook launches omit the Homebrew paths.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

readonly TEST_TIMEOUT_SECONDS=30
readonly STACK='mutable() & ::@ ~ empty()'
readonly TIP="heads(${STACK})"
readonly CHECKS="swiftformat --lint . \
&& swiftlint --strict \
&& swift build --build-tests --enable-index-store \
&& gtimeout ${TEST_TIMEOUT_SECONDS} swift test --parallel \
&& periphery scan --strict"

# Inline so formatting does not depend on unversioned .jj/repo/config.toml.
readonly FORMAT_CONFIG=(
    --config 'fix.tools.swiftformat.command=["scripts/format-stdin.sh", "$path"]'
    --config 'fix.tools.swiftformat.patterns=["glob:\"**/*.swift\""]'
    --config 'fix.tools.swiftformat.enabled=true'
)

usage() {
    echo "Usage: $0 [--full|-f]"
    echo "  --full, -f  Format and check every mutable revision, not only the tip."
}

full=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full | -f) full=true; shift ;;
        -h | --help) usage; exit 0 ;;
        # Git hooks receive <remote> <url>; they select nothing here.
        [^-]*) shift ;;
        *) echo "Error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
    esac
done

if root="$(jj --ignore-working-copy root 2> /dev/null)"; then
    use_jj=true
elif root="$(git rev-parse --show-toplevel 2> /dev/null)"; then
    use_jj=false
else
    echo "==> Not a jj or Git repository, skipping pre-push checks."
    exit 0
fi
cd "${root}"

if [[ "${use_jj}" == false ]]; then
    # Formatting the working tree does not change the commits being pushed.
    if ! swiftformat --lint . --quiet; then
        swiftformat . --quiet
        echo "==> swiftformat reformatted the working tree. Commit the changes and push again." >&2
        exit 1
    fi
    echo "==> Checking working tree"
    bash -c "${CHECKS}"
    echo "==> All checks passed."
    exit 0
fi

stack="$(jj log --no-graph -r "${STACK}" -T 'change_id ++ "\n"')"
if [[ -z "${stack}" ]]; then
    echo "==> No non-empty mutable revisions in ${STACK}, nothing to check."
    exit 0
fi

if [[ "${full}" == true ]]; then
    echo "==> Formatting ${STACK}"
    jj "${FORMAT_CONFIG[@]}" fix -s "roots(${STACK})"
    echo "==> Checking each revision in ${STACK}"
    jj run --root --ignore-changes -r "${STACK}" -- bash -c "${CHECKS}"
else
    # Checks run in the working copy; when @ is empty its tree is the tip's.
    echo "==> Formatting tip ${TIP}"
    jj "${FORMAT_CONFIG[@]}" fix -s "${TIP}"
    echo "==> Checking tip $(jj log --no-graph -r "${TIP}" -T 'change_id.short() ++ " " ++ coalesce(description.first_line(), "(no description)")')"
    bash -c "${CHECKS}"
fi

echo "==> All checks passed."
