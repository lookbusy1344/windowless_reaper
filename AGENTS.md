# Project Guidelines

## Version control (read first)

Before the first VCS command, run `jj --ignore-working-copy root`. This may be a jj repo on one machine and plain Git on another.

**IMPORTANT:** if it succeeds, use `jj` for all VCS commands, including `log`, `show`, `status` and `diff`. Do not run `git` on jj repos. The `gitStatus` snapshot in the session context is not a reason to use git.

jj has no commit hooks. Run `scripts/pre-commit.sh` before `jj commit`, `jj describe` (when finalising a change) and `jj squash`. It checks the files changed in `@` and skips the Swift checks when no Swift source or tool config changed.

Before `jj git push` or moving a shared bookmark, run `scripts/pre-push.sh`. By default it formats the tip (newest non-empty mutable revision) with `jj fix` (`scripts/format-stdin.sh`, which runs `swiftformat` with the repo `.swiftformat`), then runs the CI gates on it: `swiftformat --lint .`, `swiftlint --strict`, `swift build --build-tests --enable-index-store`, `gtimeout 30 swift test --parallel` and `periphery scan --strict`. The tip check is the full pre-push gate. Do not pass `--full` unless asked: it formats every mutable revision in `::@` and checks each in its own checkout via `jj run`, with a cold build per revision.

`scripts/agent-pre-push-hook.sh` runs the tip check on every push command and blocks the push on failure. Claude Code (`.claude/settings.json`) and Codex (`.codex/hooks.json`) call it as a `PreToolUse` hook. The hook checks the tip of `@`, not the bookmark being pushed, so push only the bookmark you are working on: the one on `@-`, with an empty `@` above it.

In a plain Git checkout the Git `pre-commit` and `pre-push` hooks run these scripts.

Push only on explicit request. "Push this" means: if `@` is non-empty, `jj commit` it (after the pre-commit checks). Move the bookmark to `@-` with `jj bookmark set <name> -r @-`, then `jj git push --bookmark <name>`. Use the bookmark already on the stack; otherwise `main`. Never push any other bookmark. Do not use `jj git push -c`.

## Personal information

Exclude PII from every commit, commit message and bookmark name: real names, email addresses, usernames, machine paths such as `/Users/<name>/`, hostnames, tokens and credentials. Check the diff before `jj commit`, `jj describe` (finalising) and `git commit`.

## General

SwiftPM only. No `.xcodeproj`, no `xcodebuild`.

## Swift version

We use the Swift toolchain bundled with the installed Xcode.
`Package.swift`'s `swift-tools-version` is the SwiftPM floor (currently 6.2),
not a cap: newer language behaviour (e.g. relaxed region-isolation checks) is
expected and relied on.

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
swift build --build-tests --enable-index-store
periphery scan --strict
```

If periphery reports `index store path does not exist`, the `.build` cache
predates the index store. Delete `.build/out` and rebuild.

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

All six gates below must be clean before commit. "Pre-existing" is not a
valid excuse — if a gate is red when you sit down to commit, you fix it as
part of the commit (or in a preceding commit on the same branch). Never
commit on top of a red gate and leave it for later.

- `swiftformat --lint .` clean
- `swiftlint --strict` clean
- `gtimeout 30 swift test --parallel` green
- `periphery scan --strict` clean (after `swift build --build-tests --enable-index-store`)
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
