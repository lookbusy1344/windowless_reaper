# Windowless Reaper for macOS

![wreaper logo](wreaper_logo.jpg)

`wreaper` (a portmanteau of **w**indowless + **reaper**) is a
macOS background daemon that politely terminates apps the user has forgotten
about — apps that have been running with **no visible window** for longer
than a per-app timeout. It is strictly allowlist-driven: only bundle IDs
named in the config are ever candidates.

- Whitelist only: no app is touched without an explicit rule
- Only windowless apps: visible or minimised windows are never touched
- Polite termination: always `terminate()`, never `forceTerminate()`
- Daemon checks every 30s by default, with hot-reloadable config. Minimal system resources used
- Behaves well under sleep/wake — no false reaps after wake, and sleep does not advance timers
- CLI supports one-shot checks and clears for manual use `wreaper check` / `wreaper clear`

## Why

macOS apps routinely linger after the last window is closed by clicking close (the red circle). This is great because it allows them to restart almost instantly, but they consume RAM and other system resources as a downside. `wreaper` monitors them and, once an app has been windowless for the configured timeout, sends a polite
`NSRunningApplication.terminate()`. If the app vetoes (e.g. unsaved work), the
timer resets and nothing is forced.

Only whitelisted apps are candidates, and no running or minimised window is ever closed. So there should be zero chance of losing work.

However use at your own risk!

I also have Raycast configured to call `wreaper clear` on `opt`+`cmd`+`w` which works really well.

---

## Install

### Prebuilt release

Each `v*` tag publishes an **ad-hoc signed** binary, a tarball, and
`SHA256SUMS` to [GitHub Releases](../../releases):

```bash
curl -L -o wreaper \
  https://github.com/<owner>/windowless_reaper/releases/latest/download/wreaper
chmod +x wreaper
# A browser download is quarantined; clear it once:
#   xattr -dr com.apple.quarantine ./wreaper
```

`wreaper --version` reports the tag and commit it was built from, e.g.
`1.2.0 (3f29b14f08eb)`. Ad-hoc signing carries no Developer-ID identity, so
Accessibility is still granted manually (below). See `DISTRIBUTION.md` for the
signing-mode tradeoffs.

### Build from source

Requires Swift 6.2+ (pinned in `.swift-version` and `Package.swift`), tested
with the Xcode 16+ toolchain. SwiftPM only — there is no `.xcodeproj` or
`.xcworkspace`. You can open `Package.swift` in Xcode to browse, but builds
and tests go through `swift`.

```bash
scripts/dev-build.sh -c release              # build, stamping the live git version
scripts/sign.sh                              # ad-hoc sign with a stable identifier
cp .build/release/wreaper /usr/local/bin/    # or $(brew --prefix)/bin
wreaper config init                          # writes ~/.config/windowless-reaper/config.toml
```

`scripts/dev-build.sh` stamps the live `git describe` version + commit into
`--version` and passes extra args through to `swift build`. A plain
`swift build` skips the stamp and reports `0.0.0-dev`.

For a faster first pass at the app rules, `wreaper config scaffold` is often
the better starting point than editing from scratch: it inspects the current
running apps and emits a starter config.

Grant Accessibility permission once:
*System Settings → Privacy & Security → Accessibility → +* and add the
absolute path to `wreaper`. macOS does not expose this via API. Verify with:

```bash
wreaper permissions check
```

`DISTRIBUTION.md` covers the tag-triggered ad-hoc release workflow and the
signed/notarised release flow.
For more operational detail, see [docs/wreaper_notes.md](docs/wreaper_notes.md), which covers Accessibility grant/verification, daemon install/update, log locations, and `launchctl` lifecycle.

---

## One-shot commands

`wreaper` supports two operating modes:

- One-shot CLI commands: run once, print/report the result, then exit.
- A persistent `launchd` daemon: run continuously in the background and
  reload config on save.

The two one-shot commands below are useful for manual verification and
explicit fire-and-exit use. For continuous background reaping, use the
`launchd` workflow in [Live-running under launchd](#live-running-under-launchd):

- `wreaper check` — dry-run a single tick, print decisions, exit
  non-zero if any rule would evict. Good for verifying config.
- `wreaper clear` — terminate every allowlisted bundle that is
  fully windowless right now, honouring `clear_cooldown` so
  just-launched apps are spared. Designed for explicit one-shot use.

See [Manually test before going live](#manually-test-before-going-live)
for full output samples and flags. The `launchd` section below documents
the persistent background setup.

---

## Configure

Configuration lives at `~/.config/windowless-reaper/config.toml`. Edit it
freely — `wreaper run` reloads on save without a restart. `poll_interval`
changes take effect on the next tick after reload. `log_level` changes apply
unless `--log-level` was passed on the command line, in which case the CLI
wins.

For initial setup, the fastest workflow is usually:

1. Run `wreaper config init` to create the config file location.
2. Run `wreaper config scaffold` to generate starter app rules from the
   current process list.
3. Edit the generated TOML to keep only the bundle IDs you actually want
   allowlisted.

### Minimal example

```toml
[settings]
poll_interval     = "30s"
log_level         = "info"
dry_run           = false
default_cooldown  = "5x"
default_timeout   = "10m"   # used by any rule with timeout = "default"

[apps."com.apple.Safari"]
timeout = "3m"

[apps."com.apple.mail"]
timeout  = "10m"
cooldown = "20m"

[apps."com.tinyspeck.slackmacgap"]
timeout = "default"
```

### `[settings]` keys

| key                | type     | meaning                                                                       |
|--------------------|----------|-------------------------------------------------------------------------------|
| `poll_interval`    | duration | how often the engine ticks (e.g. `15s`, `1m`). Default `30s`, minimum `10s`.  |
| `log_level`        | string   | `trace` / `debug` / `info` / `notice` / `warn` / `error` (`warning` accepted).|
| `dry_run`          | bool     | log decisions but never terminate.                                            |
| `default_cooldown` | duration | applied when a rule omits `cooldown`. `5x` means 5 × the rule timeout.        |
| `default_timeout`  | duration | fallback for any rule written as `timeout = "default"`. Optional.             |
| `clear_cooldown`   | duration | `wreaper clear` skips bundles whose newest PID launched within this window. Default `30s`, minimum `10s`. Has no effect on `run`/`check`. |

### `[apps."<bundle-id>"]` keys

| key        | required | meaning                                                                                       |
|------------|----------|-----------------------------------------------------------------------------------------------|
| `timeout`  | yes      | continuous windowless time before termination. `"none"` keeps the entry inert; `"default"` inherits `[settings].default_timeout`. |
| `cooldown` | no       | post-kill ignore window. Falls back to `default_cooldown`. `"none"` also falls back.          |

Keys are `CFBundleIdentifier` strings — **never display names**. Apps not
listed here are never touched.

Duration syntax: `30s`, `5m`, `2h`, `1d`. Minimum 10s — anything shorter is a
load-time error. `cooldown` also accepts `Nx` (multiplier of this rule's
`timeout`).

### Discover candidate bundle IDs

```bash
wreaper status                       # AX window state for every regular app
wreaper config scaffold              # only currently-windowless apps, timeout="none"
wreaper config scaffold --all-running
wreaper config scaffold --include-system
```

`scaffold` emits inert `timeout = "none"` entries; replace each with a real
duration before enabling the rule.

### Validate

```bash
wreaper config validate              # uses default path, exits non-zero on error
wreaper config validate ./alt.toml   # validate a specific file
wreaper config show                  # parse + print canonical TOML
```

---

## Manually test before going live

`wreaper` terminates real apps. Always exercise the config in dry-run mode
before letting launchd run it.

### 1. One-shot tick — `wreaper check`

Runs a single dry-run tick and prints decisions. Exits `1` if at least one
allowlisted app would be reaped:

```
ignore      com.example.notlisted              age=4h12m
track       com.tinyspeck.slackmacgap          age=15m
would-evict com.apple.mail pids=[1742]         age=2h
cooldown    com.apple.Safari
```

`age=` shows how long ago the bundle's newest PID launched (omitted when
the workspace didn't record a launch date). This is the fastest way to
sanity-check a rule change.

### 2. One-shot reap — `wreaper clear`

Like `check`, but instead of waiting for each app's `timeout`, every
allowlisted bundle that is currently fully windowless is terminated in a
single pass. Runs without prompts so it can be invoked directly from the CLI
or other explicit automation:

```
skip       com.tinyspeck.slackmacgap has-window     age=5m
skip       com.apple.Notes just-launched            age=8s
terminated com.apple.mail pids=[1742]               age=2h
vetoed     com.apple.Safari pids=[2031]             age=45m
```

Rules with `timeout = "none"` are skipped (allowlisted but inert).
Bundles whose newest PID launched within `[settings].clear_cooldown`
(default `30s`) are left alone with `just-launched` — this stops the
command killing apps the user only just opened. PIDs without a known
launch date are treated as old enough to reap. `--dry-run` is honoured;
under dry-run, kill lines read `would-evict …` instead. Exits 0 once
the pass completes, regardless of how many apps were reaped or vetoed.

### 3. Foreground engine — `wreaper run --dry-run --log-level debug`

```bash
wreaper run --dry-run --log-level debug
```

Logs go to stderr. Useful events to watch for:

- `starting config=… logLevel=debug pollInterval=… dryRun=true`
- `would terminate <bundle> pids=[…]`
- `termination vetoed <bundle> — timer reset`
- `config reloaded path=…`
- `skipping tick after wake (grace period)` after a sleep/wake.

Hot reload: edit the config in another shell and save — the running engine
picks up the change without a restart.

### 4. Inspect AX state — `wreaper status`

Prints the window classification (`visible` / `none` / `minimised`) for every
regular app. Use this to confirm an app really is windowless before adding it
to the allowlist.

### 5. Self-contained report — `wreaper diagnose`

Renders version, AX trust state, effective log level / dry-run, config path,
LaunchAgent install status, and recent decisions. Attach the output to bug
reports.

### 6. Integration smoke tests

The real AppKit/AX smoke tests are opt-in and only run from a GUI console
session:

```bash
WREAPER_RUN_INTEGRATION_TESTS=1 swift test --filter Testing.Tag/integration
```

### Suggested rollout

1. Pick one low-risk app and add a rule with a generous `timeout`.
2. Set `dry_run = true` in `[settings]`.
3. Run foreground for ≥ 30 minutes with `--log-level debug`; confirm the
   `would terminate …` lines name the bundles and PIDs you expect.
4. Install under launchd (next section) with `dry_run = true` still set.
5. Tail the launchd log for a day. Only then flip `dry_run = false` — hot
   reload picks it up.
6. To back out at any time: `wreaper uninstall --user`.

---

## Live-running under launchd

`wreaper install --user` is intended for routine background use under
`launchd`. Local soak testing has now run for roughly 14 days without
observed memory growth, sleep/wake regressions, or `launchd` stability
issues. That does not remove the need to validate your own rule set, but
the install path is no longer treated as experimental.

Operational details for install, update, restart, logs, and disable/uninstall
are in [docs/wreaper_notes.md](docs/wreaper_notes.md).

### Install/update summary

First-time daemon install:

1. Build and sign the binary.
2. Copy it to its stable install path.
3. Grant Accessibility to that exact path in System Settings.
4. Verify with `wreaper permissions check`.
5. Load the LaunchAgent with `wreaper install --user`.

Updating the daemon after a rebuild:

1. Rebuild and sign the new binary.
2. Replace the binary at the same installed path.
3. Restart the running agent with `launchctl kickstart -k gui/$(id -u)/<label>`.
4. Confirm the agent is running and logging normally.

If the install path and signing identifier stay stable, you should not need
to re-grant Accessibility on update.

```bash
wreaper install --user                  # write & load ~/Library/LaunchAgents/com.user.windowless-reaper.plist
wreaper install --user --print-only     # preview the plist and launchctl actions
wreaper install --user --force          # replace an existing install
wreaper install --user --prefix /opt/homebrew   # override binary search prefix
wreaper uninstall --user
```

The plist runs `wreaper run` with `RunAtLoad=true` and `KeepAlive=true`, as
`ProcessType=Background`.

### Suggested soak before enabling real terminations

A foreground `wreaper run` is not the same evidence as the same binary
running under launchd: signal delivery, session type, log routing, and
whether `NSWorkspace` notifications arrive in the agent's session all
differ. Before flipping `dry_run = false`, soak the installed daemon for
at least 72 hours and diff its `runtime-health` counters.

The engine emits a `runtime-health` log line on the first tick and again
once every hour after that (see `ReaperEngine.healthLogInterval`). One
line per hour is plenty for a 72hr window without drowning the log.

#### Procedure

1. **Install the daemon** (build + sign + load).

```bash
scripts/dev-build.sh -c release
scripts/sign.sh
cp .build/release/wreaper "$(brew --prefix)/bin/"
wreaper install --user
```

To uninstall later:

```
wreaper uninstall --user
```

Inspect runtime status anytime with `launchctl print gui/$(id -u)/<label>` (the exact label is printed by the install command).

```
launchctl print gui/$(id -u)/com.user.windowless-reaper
```

After replacing the binary you need to bounce the agent so launchd re-execs the new copy (the running process keeps the old inode):

```
launchctl kickstart -k gui/$(id -u)/<label>
```


2. **Capture the baseline.** The first tick fires the seed snapshot
   within a few seconds of load; subsequent snapshots fire hourly.
   Under launchd, `wreaper run` installs a rotating file sink at
   `~/Library/Logs/windowless-reaper.log` — unified logging
   (`log show`) is not used.

   ```bash
   sleep 10
   grep "runtime-health" ~/Library/Logs/windowless-reaper.log \
     | head -1 > /tmp/wreaper-soak-baseline.log
   cat /tmp/wreaper-soak-baseline.log
   ```

   If the file is empty or missing, the agent is not running under
   launchd (e.g. you started `wreaper run` in a shell — that path
   logs to stderr instead). Confirm with
   `launchctl print gui/$(id -u)/com.user.windowless-reaper`.

3. **Force the interesting events.** Natural use over 72hrs may not hit
   dark wake on AC. Schedule explicit cycles so the wake-path counters
   actually move. Twice a day is enough:

   ```bash
   sudo pmset schedule sleep "$(date -v+8H '+%m/%d/%y %H:%M:%S')"
   sudo pmset schedule wake  "$(date -v+8H30M '+%m/%d/%y %H:%M:%S')"
   ```

   Also close the lid on AC once during the window to exercise dark wake.

4. **Capture the final snapshot at 72h.** The file sink rotates at
   ~5 MB, so include the previous segment if it exists.

   ```bash
   cat ~/Library/Logs/windowless-reaper.log.1 \
       ~/Library/Logs/windowless-reaper.log 2>/dev/null \
     > /tmp/wreaper-soak.log
   grep "runtime-health" /tmp/wreaper-soak.log | tail -1 \
     > /tmp/wreaper-soak-final.log
   launchctl print "gui/$UID/com.user.windowless-reaper" \
     | grep -E "last exit|state|runs" \
     > /tmp/wreaper-soak-launchctl.log
   ```

5. **Diff.**

   ```bash
   diff /tmp/wreaper-soak-baseline.log /tmp/wreaper-soak-final.log
   cat /tmp/wreaper-soak-launchctl.log
   ```

#### Pass criteria

- `launchctl print` shows `runs = 1` and no `last exit reason` — the
  daemon never crashed. **Any relaunch fails the soak**; investigate the
  exit reason before re-trying.
- `skipped_grace` is roughly the number of sleep/wake cycles you forced
  (one grace tick per wake).
- `skipped_implicit_wake` is low. A handful is normal (kernel wakes
  during long suspensions); a count comparable to `skipped_grace` means
  `NSWorkspace` is not firing under launchd — that **is** the bug and
  the gate must stay up.
- `skipped_not_visible` > 0 if you closed the lid on AC — confirms the
  screen-power gate is observing the agent's session.
- `checkpoint_save_failures` is 0.
- `ticks` is consistent with `72h / poll_interval` minus the skips.

If all five hold, you have real evidence the daemon behaves under
launchd and the gate can be lifted (remove the banner above and the
stderr warning in `wreaper run`).

### Log files

Under launchd, `wreaper` writes two files in `~/Library/Logs/`:

- `windowless-reaper.log` — the main application log. Written in-process by
  a rotating handler, so it stays size-capped without external `logrotate`.
  This is what you tail day-to-day.
- `windowless-reaper.stderr.log` — launchd's `StandardOutPath` /
  `StandardErrorPath`. Reserved for pre-bootstrap output (dyld errors, Swift
  fatals); empty in normal operation.

When `wreaper run` is launched interactively (not via launchd) it skips the
file sink and logs to stderr instead.

### Observe

```bash
tail -f ~/Library/Logs/windowless-reaper.log
launchctl print gui/$UID/com.user.windowless-reaper
wreaper diagnose
```

### Change config while running

Save the file. The watcher picks it up and the engine swaps in the new config
on the next tick. The reload also re-reads `log_level` unless the launchctl
invocation passed `--log-level` (the bundled plist does not).

### Stop temporarily without uninstalling

```bash
launchctl bootout gui/$UID/com.user.windowless-reaper
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.user.windowless-reaper.plist
```

### Signal handling

The foreground process honours `SIGINT` / `SIGTERM` for clean shutdown.
launchd uses `SIGTERM` on `bootout` — no force-kill needed.

### Daemon crashlooping with `last exit code = 64: EX_USAGE`

Symptom: `launchctl print` shows `runs` climbing every ~10 s with
`last exit code = 64: EX_USAGE`. The log file repeats the same
`[wreaper] starting …` line and nothing after it.

`64` is `ValidationError` from `wreaper run`. The most common cause is
Accessibility being denied to the binary launchd actually executes
(`/usr/local/bin/wreaper`) even though `wreaper permissions check` from
your shell reports `granted`. That happens when the AX grant is keyed
to **Terminal's responsible-process chain** rather than to wreaper's
own codesigning identity — interactive shells inherit Terminal's grant;
launchd-spawned processes do not.

The failure path is silent because `ValidationError` text goes to
stderr, which the LaunchAgent redirects to `/dev/null`. Only the
pre-check `starting …` line reaches the file sink.

Recovery:

```bash
# 1. confirm the signature identifier is correct
codesign -dv /usr/local/bin/wreaper 2>&1 | grep Identifier
#   expect: Identifier=com.user.windowless-reaper
#   if not, re-sign with scripts/sign.sh and reinstall

# 2. stop the loop
launchctl bootout gui/$(id -u)/com.user.windowless-reaper 2>/dev/null

# 3. remove any existing "wreaper" entry in
#    System Settings → Privacy & Security → Accessibility (use the "−"
#    button). tccutil cannot target wreaper — it is a bare CLI binary
#    with no bundle identifier, so `tccutil reset Accessibility
#    com.user.windowless-reaper` returns OSStatus -10814.

# 4. bootstrap once — this first attempt will still fail, but it
#    registers wreaper with TCC under the launchd attribution path so
#    the next grant is keyed to the correct identity
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.windowless-reaper.plist
sleep 3

# 5. in Accessibility, click "+", Cmd-Shift-G, enter
#       /usr/local/bin/wreaper
#    add it, toggle ON.

# 6. restart the agent to pick up the fresh grant
launchctl kickstart -k gui/$(id -u)/com.user.windowless-reaper
sleep 5
launchctl print gui/$(id -u)/com.user.windowless-reaper | grep -E "state|runs|last exit"
```

Healthy state shows `state = running`, `last exit code = 0`, and the
log gains lines past `starting …` (power observers, checkpoint
restored, engine `run started`, seed `runtime-health`).

If the crashloop persists with the AX grant correctly placed, run
`/usr/local/bin/wreaper run` from a shell — that hits the same code
path with stderr attached, and the `ValidationError` text will print
to the terminal instead of disappearing into `/dev/null`.

---

## CLI reference

```
wreaper run                    # engine loop (also what the LaunchAgent runs)
wreaper check                  # one tick, print decisions, exit non-zero if any would evict
wreaper clear                  # politely terminate every allowlisted app that is windowless right now
wreaper status                 # AX window state per running regular app
wreaper config init [--force]
wreaper config show [--config <path>]
wreaper config validate [path]
wreaper config scaffold [--all-running] [--include-system]
wreaper permissions check
wreaper permissions request    # nudge macOS to surface the AX prompt
wreaper permissions path       # print the absolute binary path TCC tracks
wreaper install --user [--prefix <path>] [--print-only] [--force]
wreaper uninstall --user [--print-only]
wreaper diagnose               # version, AX state, config path, decisions, log tail
```

Global flags accepted by `run`, `check`, `clear`, `status`, `diagnose`:

- `--config <path>` — override the config file path.
- `--log-level <level>` — `trace|debug|info|notice|warn|error`.
- `--dry-run` — log decisions but never terminate.

---

## Concepts

- **Allowlist only.** No app is ever a candidate unless its bundle ID has a rule.
- **Timeout vs cooldown.** `timeout` measures continuous windowless time before
  the first termination. `cooldown` measures how long the same bundle stays
  ignored after a successful termination.
- **Polite termination.** Always `terminate()`, never `forceTerminate()`. If an
  app vetoes (unsaved work, modal dialog), the timeout tracker resets and no
  cooldown starts.
- **Minimised counts as visible.** Minimised windows are user-managed state,
  not abandoned background work.
- **Suspending clock.** All timeouts use `SuspendingClock` — laptop sleep does
  not advance them. A post-wake grace tick is skipped to avoid false reaps.
- **Cooldown after kill.** Suppresses immediate re-reaping if the OS or a
  login item auto-relaunches the app.

---

## Sleep/wake caveats

macOS does not expose a single reliable "the system was suspended" signal,
so `wreaper` combines four orthogonal signals — two as a `SleepWakeObserver`
composite (`NSWorkspace` sleep/wake + `IORegisterForSystemPower`) and two
as independent pre-tick gates inside the run loop (`NSWorkspace` screen
power for dark-wake / display-sleep, and a `ContinuousClock`-vs-
`SuspendingClock` drift detector). The pre-tick order is:
`isAsleep → isUserVisible → consumeGraceTick → drift` (see
`ReaperEngine.shouldSkipTick`).

Field logs show the kernel-side observers regularly going silent across
both AC dark wakes (Power Nap, maintenance) and — more surprisingly —
battery sleeps, with the drift detector being the only signal that
catches dozens of intermediate kernel wakes during a long suspension.
Correctness is held by the drift backstop (no spurious evictions have
been observed), but dark-wake *visibility* on AC and battery is
imperfect and the post-wake grace is a single tick, which can be tight
if `poll_interval` is very short. See
[`docs/sleep-wake-log-guide.md`](docs/sleep-wake-log-guide.md) for log
patterns, two recorded incidents (2026-05-13), and the remediation plan.

---

## Development

[`CLAUDE.md`](CLAUDE.md) contains build, test, lint, and pre-commit commands
for contributors (including those using AI coding assistants). Distribution and
release signing live in [`DISTRIBUTION.md`](DISTRIBUTION.md).

## License

MIT — see [`LICENSE`](LICENSE).
