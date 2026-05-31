# Sleep/wake log guide

How to read `wreaper` logs around suspension events, what each log subsystem
should produce on AC vs battery, which patterns indicate trouble, and where
to look in the code when something goes wrong.

## Cast of subsystems

The reaper has three independent observers that contribute to "is the system
suspended or just-woken?" decisions. Each writes to its own log label so you
can correlate signals across them:

| Label              | Source                                     | What it sees                                                                                                |
| ------------------ | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `wreaper.power`    | `NSWorkspaceScreenWake`                    | `screensDidSleep` / `screensDidWake` — display power transitions.                                           |
| `wreaper.sleepwake`| `NSWorkspaceSleepWake`                     | `willSleepNotification` / `didWakeNotification` — full user sleep/wake only.                                |
| `wreaper.iokit-power` | `IOKitSleepWake`                        | `IORegisterForSystemPower` — kernel-level, fires for dark wake too.                                         |
| `wreaper.engine`   | `ReaperEngine.tick`                        | Per-tick decisions, plus the `implicit wake detected` short-circuit when continuous-vs-suspending drift exceeds 5 s. |

The three observers exist because no single API covers every macOS power
state cleanly — see *Why so many observers?* below.

## What you should see — by power state

### On battery, full user sleep (lid close, idle timeout)

A clean sleep/wake pair, one or two grace skips, then resumption.

```
notice wreaper.sleepwake: system will sleep
notice wreaper.power: power state video=off
notice wreaper.iokit-power: system will sleep (acknowledged)
… (laptop asleep; no ticks; SuspendingClock paused) …
notice wreaper.iokit-power: system has powered on — next tick will be skipped (AX grace period)
notice wreaper.power: power state video=on
notice wreaper.sleepwake: system wake — next tick will be skipped (AX grace period)
notice wreaper.engine: skipping tick after wake (grace period)
debug  wreaper.engine: tick start snapshots=…  ← first real tick post-wake
```

Both wake sources arming the grace flag is fine — `CompositeSleepWakeObserver`
drains every child each call, so only one tick is skipped overall.

### On AC, dark wake / Power Nap (the case that originally bit us)

The screen-off interval may contain *many* brief dark wakes for background
maintenance. NSWorkspace stays silent across these; only IOKit and the drift
detector are reliable.

Expected when IOKit catches it:

```
notice wreaper.iokit-power: system will sleep (acknowledged)
… brief dark wake …
notice wreaper.iokit-power: system has powered on — next tick will be skipped (AX grace period)
notice wreaper.engine: skipping tick after wake (grace period)
```

Expected when even IOKit missed it (the belt-and-braces case the drift
detector exists for):

```
notice wreaper.engine: skipping tick — implicit wake detected (wall +Xs, suspending +Ys)
```

`X` will be much larger than `Y` — the bigger the gap between them, the
longer the system was actually suspended.

### Display sleep without system sleep

`screensDidSleepNotification` fires but no IOKit sleep arrives. The outer
`run` loop suspends:

```
notice wreaper.power: power state video=off
notice wreaper.engine: visibility=off — suspending tick loop
… (no ticks until display wakes) …
notice wreaper.power: power state video=on
notice wreaper.engine: run resumed — user-visible
```

Both clocks advance equally here (the CPU is awake) — the drift detector
should *not* fire.

## Pathological patterns and what to do

### 1. Eviction immediately after suspension with no skip

**Symptom.** `decision evict …` followed by `terminated …` for several
tracked bundles, with a wallclock gap before the tick that has no matching
`skipping tick` line.

```
debug wreaper.engine: tick start snapshots=…   ← 10:38:57
debug wreaper.engine: tick start snapshots=…   ← 11:04:14 (25 min later)
notice wreaper.engine: terminated com.microsoft.VSCode pids=[…]
```

**Diagnosis.** No grace skip fired despite real suspension. Check both:
- Was `wreaper.iokit-power: system has powered on` logged just before the
  tick? If not, IOKit either didn't register at boot or didn't deliver.
- What were the actual clock deltas? The drift detector should have logged
  `wall +X, suspending +Y` if the gap was real. If neither fired, the
  process was likely *not* suspended — the gap is real wallclock and the
  apps did exceed their timeout.

**Fix paths.**
- Confirm `iokit power observer started` appears once at daemon start.
  Missing → `IORegisterForSystemPower` returned `MACH_PORT_NULL`; rare,
  usually means the daemon isn't running with the rights it needs.
- If drift detector should have fired but didn't, the 5 s threshold in
  `ReaperEngine.implicitWakeDriftThreshold` may be too lax for very short
  dark wakes. Lowering it costs cache jitter tolerance.

### 2. `iokit power observer started` is missing from the boot logs

**Symptom.** Other `wreaper.iokit-power` lines never appear; only NSWorkspace
notifications drive grace skips.

**Diagnosis.** The IOKit registration silently failed (the constructor logs
an `error` line — check for `IORegisterForSystemPower failed`).

**Fix paths.**
- Daemon may be running with insufficient privileges. `wreaper` runs as a
  user LaunchAgent and should have the access it needs; if it's been moved
  to a LaunchDaemon context, double-check permissions.
- The drift detector still covers this case — but you've lost dark-wake
  visibility on AC. Treat as a reliability regression and investigate.

### 3. Repeated `implicit wake detected` lines without IOKit/NSWorkspace pairs

**Symptom.** Drift detector fires repeatedly with large `wall +X` but the
IOKit/NSWorkspace observers are silent.

**Diagnosis.** macOS is suspending the process via some path that doesn't
post power-management messages to user-space at all (uncommon — usually
indicates aggressive App Nap or a sandboxed power-management context).

**Fix paths.**
- Verify the daemon is not under App Nap. `wreaper` uses `ProcessInfo
  .processInfo.beginActivity` patterns where appropriate; if not, that's
  worth adding.
- The drift detector is already doing its job — the lack of IOKit pairs is
  a *visibility* problem, not a correctness one. App eviction won't fire
  spuriously.

### 4. Grace skip fires every tick

**Symptom.** Every tick logs `skipping tick after wake (grace period)`,
never advancing to a real `tick start`.

**Diagnosis.** Some upstream is re-arming the flag on every wake-up. Most
likely: `IOKitSleepWake.handleMessage` is mis-classifying a periodic
message as `kIOMessageSystemHasPoweredOn`. Less likely: dispatch queue
re-entrancy.

**Fix paths.**
- Log the raw `messageType` value in `handleMessage` to identify which
  IOKit message is being treated as wake. Compare against the hex table
  in `<IOKit/IOMessage.h>`.
- If the constant `0xE000_0300` (`kIOMessageSystemHasPoweredOnValue`) is
  receiving traffic that isn't a real wake, that's a regression in macOS;
  fall back to `NSWorkspace.didWakeNotification` only.

### 5. Drift detector fires after every `run resumed`

**Symptom.** Each time the outer loop comes out of `waitUntilVisible`, the
very next tick logs `implicit wake detected`.

**Diagnosis.** Expected behaviour and benign — while waiting for `visible`
no ticks ran, so the last-tick timestamps are stale relative to wallclock.
The skip is correct: the AX subsystem also needs the grace period after
display wake.

**Fix paths.** None needed. If the redundant skip log becomes noisy in
analysis, demote the level from `notice` to `debug` for the post-resume
case (would need to track a "just resumed" flag in the engine).

### 6. `iokit power: system will sleep (acknowledged)` not followed by power-on

**Symptom.** A `will sleep (acknowledged)` line, then ticks continue
firing within a few seconds.

**Diagnosis.** macOS asked permission, we allowed, but something else
vetoed the transition (active SSH session, holding a power assertion,
external display driving). The system never actually slept. Both clocks
continued to advance — drift detector won't fire. Working as designed.

**Fix paths.** None — that's the user's environment, not ours.

### 7. `wreaper.power` silent across a full user sleep

**Symptom.** `wreaper.sleepwake` and `wreaper.iokit-power` log the sleep/wake
endpoints normally, but no `power state video=off`/`video=on` lines appear
on either side.

```
notice wreaper.sleepwake: system will sleep
notice wreaper.iokit-power: system will sleep (acknowledged)
… (no `wreaper.power: video=off`) …
… asleep …
notice wreaper.iokit-power: system has powered on
notice wreaper.sleepwake: system wake
… (no `wreaper.power: video=on`) …
```

**Diagnosis.** `NSWorkspaceScreenWake` subscribes to `screensDid…`
notifications; macOS does *not* always emit a screen-power transition when
the lid closes and the system goes directly to S3. The CPU-side notification
path (NSWorkspace sleep/wake + IOKit) is what fires, and `wreaper.power`
simply has nothing to observe.

**Fix paths.** None required for correctness — the redundancy is by design
and the other two observers cover the case. Worth knowing only so that the
absence of `wreaper.power` lines isn't read as an observer failure during
triage. The "clean sleep" template at the top of this guide describes the
*maximal* output; not all three labels fire on every transition.

### 8. Eviction races AX repopulation after wake

**Symptom.** Immediately after a `skipping tick after wake` line, the
*next* tick still evicts an app that should be running.

**Diagnosis.** One grace tick wasn't enough — AX window lists hadn't
repopulated yet by the time the post-grace tick ran.

**Fix paths.**
- Increase the grace to N ticks. Currently the design is exactly one,
  justified by AX latency of a few seconds and a poll interval of 30 s+.
  If the poll interval is short (e.g. 10 s), one grace tick is ~10 s of
  real time, which may not be enough.
- Alternatively: have `consumeGraceTick` accept a count and decrement,
  set to ≥2 on wake when the configured poll interval is below some
  threshold.

## Field incident: 2026-05-13 — IOKit silent across a 68-minute AC sleep

Laptop on AC, asleep 11:52–13:00. The log showed exactly **one**
`iokit-power: system will sleep (acknowledged)` (at 11:52:18) and **zero**
`iokit-power: system has powered on` lines until the final user wake at
12:59:53. `wreaper.sleepwake` and `wreaper.power` were silent for the entire
interval too.

Between the two endpoints, the engine clearly came up at least four times
(12:09:03, 12:38:29, 12:54:15, 12:59:53) — every one caught only by the
drift detector, each with the expected shape (large `wall +X`, small
`suspending +Y`). A brief 12:09–12:23 activity burst executed three
evictions (Safari, smartgit, Zed), all of which were *already* windowless
before sleep with `SuspendingClock`-correct elapsed times — so eviction was
behaviourally correct, but the IOKit-pair invariant the log guide assumes
above was violated for the whole window.

This is **pattern #3** (drift fires without IOKit/NSWorkspace pairs) at
extended scale. Correctness was preserved by the drift detector; visibility
of dark-wake transitions on AC was not.

### Remediation plan

Ordered cheap → invasive. Take 1–3 first; only escalate if the diagnostic
in step 3 confirms the messages were delivered to us and we filtered them
out.

1. **Log unknown `messageType` at debug in `IOKitSleepWake.handleMessage`.**
   The `default: break` arm currently discards every IOKit message that
   isn't a sleep-ack or `kIOMessageSystemHasPoweredOn`. Without logging the
   raw `messageType`, we cannot tell whether IOKit was silent or whether
   we merely filtered useful messages out. One-line change at
   `Sources/WindowlessReaperCore/Engine/SleepWakeObserver+IOKit.swift`.

2. **Arm grace on `kIOMessageSystemWillPowerOn` (`0xE000_0320`)** in
   addition to `kIOMessageSystemHasPoweredOn`. WillPowerOn fires earlier in
   the wake sequence and on some dark wakes is the only message delivered.
   `consumeGraceTick` collapses duplicates, so arming on either edge is
   idempotent and cannot over-skip.

3. **Cross-check with `pmset -g log | grep -iE 'wake|sleep'`** for the
   incident's time range *before* changing code. Two outcomes:
   - pmset shows wakes we have no IOKit lines for → the gap is below
     us (kernel→user-space routing). Steps 1–2 won't help; file a
     Feedback Assistant report and rely on the drift detector.
   - pmset shows wakes that IOKit *should* have reported → step 1's
     unknown-messageType logging will reveal which constant we're missing.

4. **Adaptive grace from the drift detector.** Currently the implicit-wake
   branch in `ReaperEngine.tick` skips exactly one tick. After a multi-
   minute suspension AX can take longer to repopulate than after a brief
   dark wake. Promote the drift path to arm N grace ticks when
   `wall +X` exceeds a threshold (e.g. ≥ 2 grace ticks once X > 2 min).
   Implementation: have the drift branch call the same grace-arming code
   path as IOKit/NSWorkspace wake, with a count parameter — keeps the
   skip-accounting unified instead of forking it.

5. **`ProcessInfo.processInfo.beginActivity(options: .userInitiated …)`
   wrapping `ReaperEngine.run`.** Prevents App Nap demoting the daemon and
   starving the IOKit dispatch queue while suspended. Cheap insurance even
   if the current incident has a different root cause; the guide already
   flags App Nap under pattern #3.

6. **Regression test.** Add an engine test where the `SleepWakeObserver`
   stays silent across a `SuspendingClock` jump that exceeds the drift
   threshold, and pin two behaviours:
   - the immediate tick logs `implicit wake detected` and returns no
     decisions;
   - the *next* tick does **not** evict an app whose AX snapshot only
     looks windowless because the snapshot is stale (i.e. the grace
     accounting from step 4 holds).

   We have coverage for the implicit-wake skip itself; we don't have
   coverage pinning the post-skip eviction behaviour, which is what makes
   pattern #7 hard to spot in review.

## Field incident: 2026-05-13 — 73-minute battery sleep, 31 drift-only wakes

Same day as the AC incident above, but a different shape. Laptop on
**battery**, asleep 13:07:36 → 14:20:03 (73 minutes). The endpoints were
clean:

- `13:07:36` — `wreaper.sleepwake: system will sleep` *and*
  `wreaper.iokit-power: system will sleep (acknowledged)` fired together.
- `14:20:03` — `wreaper.iokit-power: system has powered on` *and*
  `wreaper.sleepwake: system wake` fired together; the AX grace tick was
  armed correctly.

Between them, **31** `engine: skipping tick — implicit wake detected` lines.
Suspending-clock deltas were 7–32 s per wake (real CPU activity, not jitter)
while wallclock deltas ranged 47 s – 13 m 50 s. IOKit and NSWorkspace were
silent for every one of those intermediate wakes — the drift detector was
the sole signal. No evictions, no `terminated` lines: correctness held.

Two new things this incident teaches over the 11:52 entry:

1. **The "IOKit silent across dark wakes" phenomenon is not AC-only.** This
   one happened on battery, where Power Nap is supposed to be inhibited. The
   intermediate kernel wakes still happen (thermal sampling, network coalesce,
   timer fan-out) and IOKit still doesn't notify us about them. The
   remediation plan below applies the same way on battery.
2. **`wreaper.power` (screensDidSleep/Wake) emitted nothing for either
   endpoint.** Lid-close on battery went straight to S3 without a discrete
   screen-power transition macOS chose to broadcast. See pattern #7 above —
   absence of `wreaper.power` lines around a sleep/wake pair is not, by
   itself, an observer failure.

Same pattern (#3) as the 11:52 incident at greater extent. The remediation
plan below is unchanged by this data point; it is **reinforced** by it (the
incident is reproducible across power states, so steps 1–3 are worth doing
before re-evaluating).

## Why so many observers?

Each macOS power API covers a different slice of reality:

- `NSWorkspace.willSleep/didWake` — only full user-driven sleep. Misses
  dark wake entirely. Misses some unannounced kernel suspensions.
- `NSWorkspace.screensDidSleep/Wake` — display-power transitions only. The
  CPU may still be running.
- `IORegisterForSystemPower` — kernel-level; fires for every system power
  transition including dark wake. The most reliable signal, but a C-level
  API with its own lifecycle complications.
- `ContinuousClock` vs `SuspendingClock` drift — detects suspensions that
  no API broadcasts. Pure observation, no notifications required.

The composite observer (`Sources/WindowlessReaperCore/Engine/Composite
SleepWakeObserver.swift`) ORs the first three; the drift detector lives
inside `ReaperEngine.tick`. Together they give defense in depth: any single
mechanism failing is caught by the others, and the drift detector is the
backstop that requires no kernel cooperation.

## Quick triage checklist

When investigating a suspected misfire after sleep:

1. Find the `terminated …` line for the bundle the user complained about.
2. Scan the 30 s before it for any of:
   - `skipping tick after wake (grace period)`
   - `skipping tick — implicit wake detected (wall +X, suspending +Y)`
   - `skipping tick — system not user-visible (dark wake / display sleep)`
3. If none appear, compute the gap between the previous `tick start`
   and the terminating tick — if it's much larger than `pollInterval`,
   the system probably slept and no observer caught it. That's a
   correctness bug; gather the surrounding log and file it.
4. If a skip *did* fire but the next tick still terminated, suspect grace
   duration (item 8 above).
5. Cross-reference with `pmset -g log | grep -i wake` to compare what macOS
   thought happened with what the reaper observed.
