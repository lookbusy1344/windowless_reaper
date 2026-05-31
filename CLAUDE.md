# windowless_reaper - Project guidelines

SwiftPM only. No `.xcodeproj`, no `xcodebuild`.

## Build & test

```bash
swift build
gtimeout 30 swift test --parallel
swift build -c release
```

Every `@Suite` carries `.timeLimit(.minutes(1))`; outer `gtimeout 30`
is the backstop for hangs that escape the trait. See
`docs/test-hangs.md` for diagnosis when a hang slips through.

`gtimeout` comes from GNU coreutils — install via `brew bundle` or
`brew install coreutils`.

## Lint & format (must pass before every commit)

```bash
swiftformat --lint .
swiftlint --strict
```

## Periphery (dead-code analysis)

Needs a fresh index store that includes the test target — without
`--build-tests`, periphery cannot see test references and reports false
positives ("Redundant public accessibility") for production symbols that
are only consumed across the module boundary by tests:

```bash
swift build --build-tests -Xswiftc -index-store-path -Xswiftc .build/index/store
periphery scan --strict
```

## Coverage

```bash
swift test --enable-code-coverage --parallel
scripts/coverage-gate.sh 95 90
```

## Fresh checkout

`brew bundle` (uses `Brewfile`), then `scripts/dev-setup.sh`.

## Release signing

`scripts/sign.sh` after `swift build -c release` — keeps the Accessibility
grant stable across rebuilds.

## Pre-commit checklist

All four gates below must be clean before commit. "Pre-existing" is not a
valid excuse — if a gate is red when you sit down to commit, you fix it as
part of the commit (or in a preceding commit on the same branch). Never
commit on top of a red gate and leave it for later.

- `swiftformat --lint .` clean
- `swiftlint --strict` clean
- `gtimeout 30 swift test --parallel` green
- `periphery scan --strict` clean (after `swift build --build-tests -Xswiftc -index-store-path -Xswiftc .build/index/store`)
- No new `@unchecked Sendable` / `nonisolated(unsafe)` without a justification comment
- CLI output changes ⇒ update the snapshot in `Tests/WindowlessReaperCoreTests/__Snapshots__/`

## Key rules

- TDD: failing test committed before implementation.
- Polite termination only — never `forceTerminate()`.
- Allowlist-driven: only bundle IDs named in config are ever candidates.
- Timeout / cooldown comparisons use `SuspendingClock` (system sleep does not advance timers). `ContinuousClock` is sampled *only* to compute the suspending-vs-continuous drift in `ReaperEngine.shouldSkipTick` — that gate is the backstop when `NSWorkspace`/IOKit wake signals are silent.
- No GUI, no Xcode app, no `.xcodeproj`.

## Test hangs

Per-suite `.timeLimit(.minutes(1))` is the primary bound; `gtimeout 30`
the backstop. New `@Suite` declarations must carry the trait. **If
`swift test` returns exit 124, stops mid-output, or reports
`Time limit was exceeded`: do NOT re-run blindly — read
`docs/test-hangs.md` and diagnose.**
