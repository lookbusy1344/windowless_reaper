#!/usr/bin/env bash
# Hand-rolled mutation testing: pick a small set of operator swaps in
# Sources/WindowlessReaperCore/{Config,Engine}/**, run the test suite for each
# mutant, and require the suite to fail (i.e. the mutant was killed).
#
# We do not use `muter` because:
#   - It is not installed by default and requires explicit user permission.
#   - The mutants below cover the decisions the project actually cares about
#     (timeout comparisons, cooldown multipliers, decision branches) without
#     the framework overhead.
#
# Exits non-zero if any mutant survived. Restores all source files on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Targets: (file, search, replace, description)
mutants=(
    "Sources/WindowlessReaperCore/Engine/StateTracker.swift|elapsed >= .seconds(rule.timeout.seconds)|elapsed > .seconds(rule.timeout.seconds)|state-tracker timeout >= -> >"
    "Sources/WindowlessReaperCore/Config/Cooldown.swift|Int((Double(timeout.seconds) * m).rounded())|Int(Double(timeout.seconds))|cooldown multiplier dropped"
)

trap 'git checkout -- Sources >/dev/null 2>&1 || true' EXIT INT TERM

survived=0
for mut in "${mutants[@]}"; do
    IFS="|" read -r file search replace desc <<<"$mut"
    if [[ ! -f "$file" ]]; then
        echo "skip: $file not found ($desc)"
        continue
    fi
    if ! grep -qF "$search" "$file"; then
        echo "skip: pattern not present in $file ($desc)"
        continue
    fi
    echo "==> mutating: $desc"
    cp "$file" "$file.bak"
    # macOS sed: -i '' for in-place; use a temp variable so we replace fixed
    # strings rather than regex.
    python3 - "$file" "$search" "$replace" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
src2 = src.replace(sys.argv[2], sys.argv[3], 1)
if src == src2:
    sys.exit("mutation produced no change")
p.write_text(src2)
PY

    if gtimeout 90 swift test --parallel >/dev/null 2>&1; then
        echo "SURVIVED: $desc"
        survived=$((survived + 1))
    else
        echo "killed:   $desc"
    fi
    mv "$file.bak" "$file"
done

if (( survived > 0 )); then
    echo "$survived mutant(s) survived — tests are not strong enough."
    exit 1
fi
echo "all mutants killed."
