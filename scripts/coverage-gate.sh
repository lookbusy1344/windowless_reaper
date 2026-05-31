#!/usr/bin/env bash
# Usage: scripts/coverage-gate.sh <line-threshold> <region-threshold>
#
# Swift's coverage instrumentation does not emit branch counters under SwiftPM,
# so we enforce on `regions` (the strongest available metric) instead of
# `branches`. Documented in docs/tooling-decisions.md.
#
# Coverage is aggregated by raw covered/count across the gated files — a
# single small file at 0% should not dominate a percentage average.
set -euo pipefail

LINE_THRESHOLD="${1:-95}"
REGION_THRESHOLD="${2:-90}"

PROFDATA="$(find .build -name default.profdata -path "*/codecov/*" | head -1)"
BIN="$(find .build -name windowless-reaperPackageTests -path "*/MacOS/*" ! -path "*dSYM*" | head -1)"

if [[ ! -f "$PROFDATA" ]]; then
    echo "no profdata at $PROFDATA — run: swift test --enable-code-coverage" >&2
    exit 2
fi

echo "profdata: $PROFDATA"
echo "binary:   $BIN"

# Gated files: pure logic only. Excludes:
#   - Tests/, .build/
#   - +AX.swift platform shims (require live AX permission)
#   - AccessibilityPermission.swift (TCC interaction)
#   - Clock.swift (SystemClock relies on wall-clock; TestClock exercises Clock)
#   - SleepWakeObserver+NSWorkspace.swift (NSWorkspace notifications)
IGNORE='(Tests|\.build|\+AX\.swift|AccessibilityPermission|Clock\.swift|SleepWakeObserver\+NSWorkspace|LaunchctlClient)'
GATED='Sources/WindowlessReaperCore/(Config|Engine|Duration|BundleID|Diagnostics|Logging|LaunchAgent)'

xcrun llvm-cov export "$BIN" \
    -instr-profile="$PROFDATA" \
    -ignore-filename-regex="$IGNORE" \
    -format=text \
    -summary-only \
  | jq --argjson lt "$LINE_THRESHOLD" --argjson rt "$REGION_THRESHOLD" \
       --arg gated "$GATED" '
      .data[0].files
      | map(select(.filename | test($gated)))
      | if length == 0
        then "no gated files found — skipping coverage gate"
        else
          ( reduce .[] as $f ({lc:0,lv:0,rc:0,rv:0};
              .lc += $f.summary.lines.count    | .lv += $f.summary.lines.covered |
              .rc += $f.summary.regions.count  | .rv += $f.summary.regions.covered)
          ) as $agg
          | { line:   (100 * $agg.lv / $agg.lc),
              region: (100 * $agg.rv / $agg.rc) }
          | if .line < $lt or .region < $rt
            then "coverage below gate: line=\(.line)% region=\(.region)% (line>=\($lt)%, region>=\($rt)%)" | halt_error(1)
            else "coverage ok: line=\(.line)% region=\(.region)%"
            end
        end
    '
