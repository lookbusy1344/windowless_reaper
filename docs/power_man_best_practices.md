# Power management best practices on macOS

Long-running utilities that must survive sleep/wake but stay cheap while
the screen is off live at the intersection of four overlapping macOS
subsystems: launchd, IOKit power management, NSWorkspace notifications,
and the centralised activity scheduler (CTS / `NSBackgroundActivityScheduler`).
None of those subsystems is sufficient on its own, and the public
documentation across them is partially deprecated, scattered, and in a
couple of cases (dark wake) explicitly silent about behaviour that hits
real apps every day.

This document captures what we currently believe is the right approach
for any long-running macOS app that must coexist with sleep correctly.
The generic guidance lives in §§1–2; §3 is a short field-incident
narrative and §4 a case-study walk-through of how the patterns
materialise in `wreaper`. §5 is a cheat-sheet of antipatterns to
recognise in review.

**How to read this doc**

- New to macOS sleep/wake: read §§1, 2.3, 2.7, 2.8, 2.29 in that order.
- Designing a new daemon: §§2.1–2.9 cover mechanisms; §§2.13, 2.18,
  2.24 cover state lifecycle.
- Debugging a wake-related bug: §§2.10, 2.12, 2.23, 2.29 are the
  diagnostic toolbox; §3 shows what a real incident looks like.
- Reviewing PRs: §5's antipatterns list is the quick read.

---

## 1. The macOS power state landscape

A modern Mac is not "awake" or "asleep". It cycles through at least
five distinct CPU/display configurations:

| State                  | CPU            | Display      | Notes                                                                                |
|------------------------|----------------|--------------|--------------------------------------------------------------------------------------|
| **S0 user-visible**    | Running        | On           | Normal operation.                                                                    |
| **Display sleep**      | Running        | Off          | User idle timer fired; CPU still scheduling. `NSWorkspace.screensDidSleep` fires.   |
| **Dark wake**          | Running (some) | Off          | Kernel-only resume during a sleep window for background work. Approx every 15 min.  |
| **Maintenance sleep**  | Suspended      | Off          | Standard system sleep between dark wakes.                                            |
| **S3 / standby**       | Off            | Off          | Deep sleep, RAM self-refresh only. Reached after `standbydelaylow/high`.            |

"S0"/"S3" are Intel ACPI terms. Apple Silicon does not literally reach
S3; its deepest sleep is closer to a deeply throttled S0ix-style
state. From user-space the visible behaviour — `SuspendingClock`
paused, no IOKit notifications, no scheduled wake — is the same on
both, so the table holds for design purposes.

Two facts dominate the design space:

- **Dark wake is invisible to user-space.** Apple DTS confirms that
  `IORegisterForSystemPower` does *not* deliver
  `kIOMessageSystemHasPoweredOn` for dark wake, because the system isn't
  considered "On". There is no public API at all for detecting that the
  machine is currently in a dark wake. (Apple's recommended workaround
  in DTS thread 770517 is "file a Feedback Assistant request".)
- **`SuspendingClock` and `ContinuousClock` together are an implicit
  suspension oracle.** `SuspendingClock` pauses while the system is
  asleep; `ContinuousClock` does not. Their drift across two consecutive
  ticks is a kernel-cooperation-free signal that a sleep just ended,
  whether or not any notification API fired. This is the only general
  signal that catches dark wake on AC *and* battery — see incidents in
  [`sleep-wake-log-guide.md`](sleep-wake-log-guide.md).

---

## 2. Generic best practices

Thematic guide to the subsections below:

- **Mechanisms** — 2.1 events vs polling · 2.2 coalescing · 2.3 clocks ·
  2.4 deployment vehicles · 2.5 sleep assertions · 2.6 sleep ACK ·
  2.7 dark wake · 2.8 layered observation · 2.9 LaunchAgent plist
- **Diagnostics** — 2.10 measuring · 2.12 wake reasons · 2.23 deeper
  tools · 2.29 fires-when matrix
- **State & lifecycle** — 2.13 checkpointing · 2.17 signals ·
  2.18 `Date` jumps · 2.24 restartability · 2.25 watchdog ·
  2.30 `Task.sleep` semantics
- **Permissions & UI** — 2.26 TCC re-verify · 2.28 code-sign identity ·
  2.32 Background Task Management UI
- **Performance** — 2.21 QoS · 2.22 unified logging ·
  2.31 `runningboardd` · 2.33 memory pressure
- **Edge cases** — 2.11 power source / thermal / LPM ·
  2.15 Apple Silicon vs Intel · 2.16 reproducing scenarios ·
  2.19 network across sleep · 2.20 subsystem readiness ·
  2.27 battery vs AC myth · 2.34 clamshell mode · 2.35–2.39 sandbox,
  headless, MenuBar apps, `pmset` tuning

### 2.1 Prefer events to polling

`Energy Efficiency Guide for Mac Apps` is unambiguous: timers are
expensive because each firing wakes the CPU out of a low-power state,
and during sleep they multiply by aligning with dark wakes. Where
possible:

- File / directory changes → `DispatchSourceFileSystemObject` (`DISPATCH_SOURCE_TYPE_VNODE`) or `FSEvents`.
- Process lifecycle → `NSWorkspace.didLaunch/didTerminateApplication` notifications.
- Power/display state → `NSWorkspace.screensDidSleep/Wake`, `NSWorkspace.willSleep/didWake`, `IORegisterForSystemPower`.
- Cross-process signals → XPC, distributed notifications.

If a *real* state change drives your work, use the notification, not a
timer that polls for the same state.

### 2.2 If you must poll, coalesce

When polling is unavoidable (e.g. observing third-party state that
emits no notifications — AX window lists are the canonical example),
attach generous tolerance/leeway so the kernel can align your wakeups
with everyone else's:

```swift
// Dispatch timer with 10% leeway:
source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(Int(interval * 0.1)))

// NSTimer / DispatchSourceTimer minimum: 10% of interval, more is better.
```

A 30 s interval with 3 s tolerance lets macOS fire your timer in the
same wake as another process's timer, often saving an entire CPU wake
cycle.

### 2.3 Pick the right clock

| Task                                                | Clock              |
|-----------------------------------------------------|--------------------|
| Per-app "active for N minutes" timeout              | `SuspendingClock`  |
| "How long was the last sleep?" diagnostics          | `ContinuousClock - SuspendingClock` |
| Wall-clock display the user reads                   | `Date`             |
| Hard real-time deadlines that must include sleep    | `ContinuousClock`  |
| Inter-tick measurement that must survive NTP slew   | `ContinuousClock`  |

Mixing the two clocks — using the difference of their deltas — is the
canonical way to detect that you were just suspended without relying on
any notification API.

### 2.4 Choose the right deployment vehicle

For a daemon that needs to observe and act on apps running in the
user's GUI session, the choice is essentially forced:

| Vehicle                          | When to use                                                                                   |
|----------------------------------|-----------------------------------------------------------------------------------------------|
| **LaunchAgent** (per-user)       | Anything that needs `NSWorkspace`, Accessibility, or the user's keychain. Loaded in the user session. |
| **LaunchDaemon** (system)        | System-wide services with no GUI dependency. Cannot use AppKit / NSWorkspace reliably.        |
| **`NSBackgroundActivityScheduler` / XPC Activity** | In-app deferred work where the OS decides *when* to run you. Pauses across sleep, aligns with full wake. |
| **`launchd` `StartCalendarInterval`** | One-shot periodic work where each run is independent (cron-style). Deferred entries fire on the next wake. |
| **`KeepAlive` with crash restart** | Long-lived services that must respawn on crash but should otherwise be quiescent.            |

For periodic but discretionary work, **`NSBackgroundActivityScheduler`
is Apple's preferred mechanism**: the OS chooses the firing time within
your `interval`/`tolerance` budget, defers across power/thermal
pressure, and only fires during full wake (not dark wake). The
trade-off is that you cede control of *when* — completely opaque from
outside the OS scheduler.

### 2.5 Don't accidentally hold a sleep assertion

`IOPMAssertion` types matter:

- `PreventUserIdleSystemSleep` — blocks idle sleep, allows lid-close sleep.
- `PreventSystemSleep` — blocks *all* sleep (use almost never; equivalent to `caffeinate -s`).
- `NoIdleSleepAssertion` / `NoDisplaySleepAssertion` — display-only.
- `BackgroundTaskAssertion` — lets the system sleep but defers it for a short window.

`ProcessInfo.processInfo.beginActivity(options:reason:)` is the
high-level wrapper:

- `.background` — light hint; do not block sleep, just protect from
  App Nap aggression.
- `.userInitiated` — slightly stronger, treats your process as
  foreground-equivalent for scheduling purposes.
- `.idleSystemSleepDisabled` — actively prevents idle sleep. **Do not
  set this** for any background supervisor whose product hypothesis is
  that the laptop sleeps: it defeats the entire energy goal.
- `.suddenTerminationDisabled` / `.automaticTerminationDisabled` — only
  relevant to App-Nap-eligible UI apps.

The right default for a periodic supervisor is `.background` with
no sleep-prevention bit set: tells the system you're allowed to do
work, doesn't force it to stay awake.

### 2.6 Acknowledge sleep promptly

`IORegisterForSystemPower` delivers:

- `kIOMessageCanSystemSleep` (0xE000_0270) — system *asks* permission. Reply with `IOAllowPowerChange(...)`.
- `kIOMessageSystemWillSleep` (0xE000_0280) — system *will* sleep. Reply with `IOAllowPowerChange(...)`.
- `kIOMessageSystemWillPowerOn` (0xE000_0320) — early wake notice, before user-space is fully restored.
- `kIOMessageSystemHasPoweredOn` (0xE000_0300) — full wake complete.

A daemon that fails to acknowledge `CanSystemSleep` / `WillSleep`
stalls the entire sleep transition for ~30 s while macOS waits. The
correct behaviour is "allow, always" unless the daemon has a concrete
reason to veto (and very few real daemons do — backup tools mid-write
are about the only common case).

`WillPowerOn` is worth handling — on some dark-wake-adjacent
transitions it is the only message that arrives, with `HasPoweredOn`
never following.

### 2.7 Don't expect dark wake to look like wake

The single biggest source of confusion. Concretely:

- `NSWorkspace.didWakeNotification` fires **only** for full user wake.
- `IORegisterForSystemPower` is **intentionally** silent for dark wake.
- `NSWorkspace.screensDidWakeNotification` fires only when the display
  actually re-powers.

If your code must *do* something during the dark-wake CPU window
(network maintenance, log flush, etc.) you can't use any notification
to detect it. The only options are:

1. Use `NSBackgroundActivityScheduler` and let the OS schedule you —
   this is the supported path.
2. Run a periodic `DispatchSourceTimer` and accept that you will fire
   inside dark wakes. Coalesce with leeway to align with the dark wake
   that was going to happen anyway.
3. Detect implicit wake via clock drift (compare a `SuspendingClock`
   delta against a `ContinuousClock` delta across consecutive ticks)
   when you need a "you were just suspended" signal that no API
   exposes.

If your code must *not* run during dark wake, the answer is also
`NSBackgroundActivityScheduler` — its `qos`/`interval` machinery only
runs during full wake by design.

### 2.8 Layered observation, not single source of truth

Because each individual API has known gaps, defence-in-depth is the
correct posture for any non-trivial supervisor:

```
NSWorkspace screensDidSleep/Wake   → display-power transitions
NSWorkspace willSleep/didWake      → full user sleep/wake
IORegisterForSystemPower           → kernel power transitions (no dark wake)
ContinuousClock vs SuspendingClock → catches everything else
```

A composite observer that ORs all three notification sources is the
right shape; the practical lesson from incidents is that the
clock-drift backstop must exist, because the upper three layers can
all be silent simultaneously across a multi-hour sleep. §4.19 is the
wreaper-specific implementation with the "wait for every child to
report" invariant.

### 2.9 LaunchAgent plist patterns

For a daemon that *should* survive sleep but *shouldn't* burn energy
during it:

```xml
<key>RunAtLoad</key><true/>
<key>KeepAlive</key>
<dict>
  <key>SuccessfulExit</key><false/>
  <key>Crashed</key><true/>
</dict>
<key>ProcessType</key><string>Background</string>
<key>LowPriorityIO</key><true/>
<key>Nice</key><integer>5</integer>
```

Key choices:

- `ProcessType=Background` lowers IO and scheduling priority and
  enables App Nap throttling.
- `KeepAlive=true` is a footgun — it respawns on *every* exit
  including clean shutdowns. Use the dict form to restart on crash
  only, or accept that the process must run forever.
- Avoid `StartInterval` for long-lived daemons; it duplicates what
  your own timer already does and serialises across sleep awkwardly.
- For cron-style use cases, `StartCalendarInterval` runs only when
  the system is awake; deferred entries fire on the next wake. This
  is the right vehicle for one-shot periodic work where each run is
  independent.

### 2.10 Things to measure, not guess

- `pmset -g log | grep -iE 'wake|sleep|darkwake'` is the ground-truth
  log of what the kernel thinks happened.
- `pmset -g assertions` lists every active power assertion and who
  holds it. If your daemon is unintentionally preventing sleep, this
  is where it shows up.
- Activity Monitor → Energy tab → Idle Wake Ups column. Target is
  under 1 wake per second; tens-per-second indicates poll storm.
- `log show --predicate 'subsystem == "com.apple.powerd"' --last 1h`
  is the structured equivalent of `pmset -g log`.

A daemon that *thinks* it's idle but shows 50 wakes/sec in Activity
Monitor is broken regardless of how the design reads on paper.

For a deeper look, `powermetrics` is the right tool:

```bash
sudo powermetrics --samplers tasks -i 5000 -n 6 \
  | grep -E '^your-daemon|name|wakeups'
```

This shows per-process timer wakes, IPC wakes, package-idle exits, and
GPU usage in a sampled window. A well-behaved background daemon shows
single-digit timer wakes per sample interval; a poll-storming one
shows hundreds. `taskinfo <pid>` is the modern equivalent of inspecting
`top -stats pid,command,wq,idlew` and includes `runningboardd`
assertion state.

### 2.11 Adapt to power source, thermal state, and Low Power Mode

Modern macOS exposes three runtime signals that a polite background
daemon should at least observe, even if it chooses not to act on them:

- `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType` —
  AC vs battery. Useful for tightening behaviour on battery (longer
  poll intervals, smaller working set, defer non-urgent work).
  `IOPSNotificationCreateRunLoopSource` is the event-driven flavour.
- `ProcessInfo.processInfo.thermalState` (.nominal/.fair/.serious/.critical)
  — defer discretionary work above `.fair`. The thermal subsystem
  publishes `Process​Info.thermalStateDidChangeNotification` so this is
  observable, not poll-only.
- `ProcessInfo.processInfo.isLowPowerModeEnabled` plus
  `NSProcessInfoPowerStateDidChangeNotification` — macOS gained Low
  Power Mode parity with iOS in macOS 12. Background daemons should
  treat LPM as "back off" — longer intervals, no speculative work, no
  optional network IO.

These are not just polite gestures: the system can and will throttle a
daemon that ignores them, and the throttling may take the form of
deferred timer firings that look like bugs (see incident pattern #3 in
the log guide).

### 2.12 Read wake reasons, don't guess

`pmset -g log` annotates every wake with a *reason*. The common ones:

| Reason                  | What woke us                                                                  |
|-------------------------|-------------------------------------------------------------------------------|
| `UserActivity Assertion`| Trackpad, keyboard, lid open — full wake.                                     |
| `EC.LidOpen`            | Hardware lid sensor — full wake.                                              |
| `RTC` / `RTC_ALARM`     | Scheduled wake (`pmset schedule`, Power Nap maintenance).                     |
| `BT.WakeNetwork`        | Bluetooth peripheral activity.                                                |
| `XHC1` / `EHC1` / `USB` | USB peripheral activity.                                                      |
| `DarkWake from S3`      | Maintenance/Power Nap dark wake — CPU only, no display.                       |
| `Notification`          | APNS / network maintenance dark wake.                                         |
| `Maintenance`           | OS-scheduled background activity slot (CTS).                                  |

When triaging "why did the daemon run at 03:14?", grepping
`pmset -g log` for the surrounding 60 s and reading the reason field
is usually faster than reading the daemon's own logs.

### 2.13 Checkpoint state before sleep, not on every change

A daemon that holds in-memory state (decision ring, tracker state,
last-tick timestamps) should persist a checkpoint on
`willSleepNotification` / `kIOMessageSystemWillSleep` and only then —
not on every state mutation. Two reasons:

- Writing on every change burns IO and disk wakes.
- Sleep is the only checkpoint that *matters* from a recovery POV:
  if the process crashes mid-sleep, replay from a pre-sleep checkpoint
  is dramatically cheaper than rebuilding from scratch.

The pattern:

```swift
case .willSleep:
    do {
        try state.atomicWrite(to: checkpointURL)
    } catch {
        logger.warning("checkpoint write failed: \(error) — will retry next willSleep")
    }
```

`try?` would discard the error silently, which is the wrong default
here — IO failures are real, recoverable on the next sleep, and worth
a log line. Use `Data.write(to:options:.atomic)` so a power-failure
mid-write doesn't corrupt the file. On `start()`, reload the
checkpoint; treat missing, unreadable, or unknown-schema files as
"start from `t=0`" with a warning, not a crash.

### 2.14 Dispatch discipline inside IOKit callbacks

`IONotificationPortSetDispatchQueue` runs every IOKit power message on
the queue you provided. That queue is *serial*, and macOS waits for
your sleep-ack call before it actually transitions. Two rules follow:

- Do not perform heavy work inside the callback. Set a flag, post to
  another queue, return. A `Mutex<Bool>` (or atomic) that the tick
  path reads at the next safe point is the right shape.
- Do not block on locks held by the work path. If the work loop is
  mid-flight and holding state, the callback queue stalls, and the
  sleep transition stalls with it.

Either an actor-isolated grace flag (read at the next tick) or a
plain `Mutex`-backed boolean is fine; what matters is that the
callback never `await`s on, or contends a lock with, the work loop.

### 2.15 Apple Silicon vs Intel sleep semantics

Worth knowing even when the code is identical:

- **Apple Silicon Macs sleep more deeply and more often.** Idle sleep
  is reached faster, dark wakes are shorter, and `standbydelaylow` is
  effectively immediate. `SuspendingClock`-vs-`ContinuousClock` drift
  on Apple Silicon during overnight sleep can run to the *seconds per
  minute* range — i.e. the machine is asleep more than 90% of the
  time the lid is closed.
- **Power Nap defaults differ.** On Apple Silicon, Power Nap is
  always on; on Intel it's user-toggleable in System Settings → Battery.
  Daemons cannot detect "Power Nap is off" from user-space — only the
  *effect* (no dark wakes) is observable.
- **Standby transition is invisible to user-space on both.** No public
  notification fires when the machine transitions from S0 sleep to
  standby; the only signal is that wakes stop happening for a long
  interval.

A daemon should not branch on architecture; the design should work on
both. But when reading field logs from a 16h overnight sleep, knowing
that Apple Silicon will show *fewer* IOKit pairs than the equivalent
Intel run is helpful context.

### 2.16 Reproducing sleep scenarios for testing

The mistake here is letting macOS choose when to sleep during a test
run. Force the transitions:

```bash
# Force display sleep (no CPU sleep):
pmset displaysleepnow

# Force full system sleep right now (best test signal):
pmset sleepnow

# Schedule a wake N seconds out (useful with sleepnow):
sudo pmset schedule wake "$(date -v+90S '+%m/%d/%y %H:%M:%S')"

# Block all sleep for a fixed window (regression-testing "long uptime"):
caffeinate -dis -t 600 -- ./your-daemon

# Inhibit user-idle sleep but allow lid close:
caffeinate -u -t 60
```

To reproduce dark wake specifically, you cannot do better than
"plug into AC, idle for 20 m" — there is no public way to *force* a
dark wake. A synthetic-drift test seam (advance a fake
`ContinuousClock` while pinning `SuspendingClock`, run a tick, assert
no decisions) is the deterministic substitute that avoids needing
real sleep at all. §4.13 has a worked example.

### 2.17 Signal handling on bootout

`launchctl bootout` sends `SIGTERM`, waits ~20 s, then escalates to
`SIGKILL`. A daemon that does not handle `SIGTERM` will be killed
mid-write and may corrupt its checkpoint. The minimum is:

```swift
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { Task { await engine.shutdown(); exit(0) } }
sigterm.resume()
signal(SIGTERM, SIG_IGN)  // required to receive via dispatch source
```

The same applies to `SIGINT` for interactive use. Do *not* handle
`SIGKILL` (impossible) or `SIGSTOP` (the supervisor's job, not yours).

### 2.18 `Date` can jump backwards after wake

NTP correction frequently runs shortly after wake, and a user can
change the system clock at any point during sleep. Either can move
`Date.now` *backwards* by anything from milliseconds to hours.
Anything that uses `Date` arithmetic for an interval can therefore
return a negative duration, including overflow into nonsense values.

The rule: **`Date` is only valid for wall-clock semantics that the
user reads.** Every duration, deadline, cooldown, retry-after, or
"X happened N seconds ago" calculation must use `SuspendingClock` or
`ContinuousClock`. Both are monotonic across NTP slews, user clock
changes, and DST transitions; neither has a serialisable form, which
is the right tension — durations are meaningful, instants in the
SuspendingClock are not.

For state that must round-trip to disk, persist the *duration* (e.g.
"this bundle has been windowless for 247 seconds"), not the instant.
On reload, re-anchor against `clock.now()`.

### 2.19 Network connections do not survive sleep gracefully

TCP sockets typically die silently across system sleep: the connection
is reset by the peer or by an intermediate NAT, but the local stack
doesn't learn about it until the next send (which returns `EPIPE` or
`ETIMEDOUT`) or a keepalive probe fires (which can take minutes).
HTTP/2 streams, SSE connections, WebSockets, and gRPC channels all
inherit this problem.

The correct pattern for any daemon that holds long-lived network
state:

- Use `NWPathMonitor` (Network framework) and treat every path change
  as "tear down and reopen". This catches sleep/wake *and* Wi-Fi
  network changes the user makes during sleep.
- On `didWake`, proactively close-and-reopen any persistent
  connection rather than waiting for the first request to fail.
- Drop the DNS cache on first request after wake — Apple's resolver
  is generally good about this, but stale `AAAA` records have
  produced multi-minute hangs in real apps.
- Set explicit `URLSessionConfiguration.timeoutIntervalForResource`
  ceilings so a half-open connection cannot hang the daemon
  indefinitely.

Stale connections are the single most common sleep/wake bug class in
real macOS apps. A daemon that does no network IO is exempt; one
that does anything more than a single short-lived request per wake
must adopt this pattern.

### 2.20 Subsystem readiness after wake

A wake event signals "the CPU is running again", not "every
user-space subsystem is ready". Empirically the slowest to recover:

| Subsystem            | Typical settle time | Symptoms if queried too soon                          |
|----------------------|---------------------|-------------------------------------------------------|
| Accessibility (AX)   | 1–5 s               | Window lists empty or stale, attribute reads fail.    |
| Metal / GPU          | 100–500 ms          | `MTLDevice` returns nil command queue; recreate.      |
| AVFoundation         | 200 ms – 2 s        | `AVAudioEngine` configurations require restart.       |
| External volumes     | seconds to minutes  | `EBADF` / `ENOENT` on file descriptors from pre-sleep.|
| Network              | see §2.19           | `EPIPE` / `ETIMEDOUT` minutes after first send.       |
| Bluetooth peripherals| 2–10 s              | `CBPeripheral` reads silently drop.                   |

The right model is a *per-subsystem readiness check*, not a fixed
post-wake `Thread.sleep`. Skipping one work cycle after wake (the
"grace tick" pattern) is the canonical AX instance of this
principle; equivalents exist for each row in the table — re-probe
the device, re-open the connection, retry the read once.

### 2.21 QoS classes interact with power throttling

The QoS hierarchy (`.userInteractive`, `.userInitiated`, `.default`,
`.utility`, `.background`) is not just a scheduling priority hint —
it controls how aggressively the kernel applies App Nap, thermal
throttling, and timer coalescing. For a periodic supervisor:

- **Periodic tick path**: `.utility`. Yields to user work; gets some
  App Nap protection but doesn't fight thermal throttling.
- **One-shot user-driven CLI commands**: `.userInitiated`. The user
  is waiting; finish promptly.
- **Pre-sleep checkpoint write** (§2.13): `.userInitiated`. Must
  complete before the sleep transition; latency matters more than
  efficiency for this one write.
- **Log rotation, cache trimming, anything discretionary**:
  `.background`. Lets the OS defer indefinitely.

Avoid awaiting a high-QoS task from a low-QoS context: Swift
Concurrency propagates QoS through `await` in most cases, but
`Task.detached { ... }` and queue hops can drop it. The result is
QoS inversion — a low-priority context holding state that a
high-priority context needs — and under thermal pressure it
deadlocks rather than slows down.

### 2.22 Log via `os_log` / `Logger`, not files

The unified logging system is the right substrate for daemon logs:

- **Sleep-aware.** Entries written during dark wake are buffered and
  flushed on full wake without per-call disk IO.
- **Energy-efficient.** A single centralised daemon (`logd`) does the
  IO; your process posts via shared memory.
- **Structured.** Filter by subsystem / category / privacy.
- **Persistent.** `log show --predicate '...' --last 24h` reads the
  same buffer the user sees in Console.

The pattern:

```swift
let logger = Logger(subsystem: "com.example.daemon", category: "engine")
logger.notice("system wake — grace armed")
```

Privacy formatting matters for daemons that log user-visible data
(bundle IDs, paths, usernames): `\(value, privacy: .public)` vs
`.private`. Without explicit privacy marks, `os_log` and Swift's
`Logger` redact dynamic strings in release builds — a real surprise
the first time it bites.

File logging is fine *in addition* (launchd captures `stderr`
regardless), but rotate by size only; time-based rotation across
sleep is racy and the file can be open with a stale offset when the
machine wakes.

### 2.23 Diagnostic tooling beyond `pmset`

When `pmset -g log` and Activity Monitor aren't enough:

```bash
# Export the unified log for the last hour as a portable archive:
log collect --last 1h --output /tmp/sleep.logarchive

# Query the archive offline (no impact on the live system):
log show /tmp/sleep.logarchive --predicate \
  'subsystem == "com.apple.powerd" OR subsystem == "com.example.daemon"'

# Entire-system snapshot (logs, configs, IORegistry, sample of every
# process). Email-able with the user's consent:
sysdiagnose -f /tmp

# Is the daemon hung or just sleeping? sample for 10 s:
spindump $(pgrep your-daemon) 10

# Every file/syscall the daemon does, including inside dark wakes:
sudo fs_usage -w -f filesys your-daemon
```

`sysdiagnose` is the right thing to ask for when a user reports a
hard-to-reproduce sleep/wake bug. It captures the entire IORegistry,
the unified log, and `pmset -g log` in one archive.

### 2.24 Restartability is cheaper than crash-proofing

A daemon that *survives* crash-during-sleep by checkpointing (§2.13)
and reloading on restart is fundamentally simpler than one that
tries to be crash-proof during sleep. Three invariants worth pinning:

1. **Every termination is idempotent.** If the daemon crashes after
   sending `terminate()` but before recording the cooldown, restart
   must not re-terminate the same bundle (cooldown lives in the
   checkpoint, written *before* the kill).
2. **The next tick proceeds even if the previous tick was killed
   mid-execution.** No state should be "halfway through a tick" on
   disk; checkpoint at tick boundaries only.
3. **External grants are re-verified on every start.** TCC
   (Accessibility), file access, etc. — see §2.26.

`launchd`'s `KeepAlive.Crashed=true` is the right safety net. Design
the daemon to be restart-tolerant and let the supervisor handle
recovery.

### 2.25 Watchdog vs sleep

A naïve heartbeat watchdog ("kill if no liveness signal in 5 min")
fires on every overnight sleep. Three escape hatches:

- Heartbeat with `SuspendingClock` so it pauses with the system.
- Reset the watchdog on `didWake` notifications before the next
  heartbeat check.
- Don't roll your own — let `launchd` (`KeepAlive`, `ExitTimeOut`)
  do the supervision. It already knows about sleep.

`launchd` is the right answer for daemons. Hand-rolled in-process
watchdogs that "kill if silent too long" are an antipattern for any
process that can legitimately be silent across a 9-hour overnight
sleep.

### 2.26 Re-verify TCC permissions on wake

TCC grants (Accessibility, Full Disk Access, Screen Recording, …)
are durable across sleep and restart, *but* they are silently revoked
when:

- The binary's code-sign hash changes (re-sign, re-link, rebuild).
- A major OS update occasionally clears specific entitlements.
- The user revokes the grant in System Settings.

A daemon depending on Accessibility should call
`AXIsProcessTrustedWithOptions(nil)` on every wake (`didWake` is the
right hook, not `screensDidWake`) and log a notice on transition. Do
*not* prompt — TCC handles that — but do not silently degrade either.
The user should see "AX permission lost; reaper is dormant" in the
log, not silent inaction.

### 2.27 Battery vs AC: the differences, and the myth

A common assumption is that dark wake is an "AC-only Power Nap
thing" and that battery sleep is quiet. Field data and Apple's
documentation both disagree.

**What is genuinely different on battery vs AC:**

| Behaviour                                | AC                                 | Battery                                           |
|------------------------------------------|------------------------------------|---------------------------------------------------|
| Power Nap on Intel                       | Default ON, user-toggleable        | Default OFF, user-toggleable                      |
| Power Nap on Apple Silicon               | Always on, full feature set        | Always on, reduced — no Time Machine, no SW updates |
| Dark wake *frequency*                    | ~15 min, can be tighter            | Less predictable; can be sparse or frequent       |
| Dark wake *duration*                     | Up to ~30 s for maintenance        | Shorter; system returns to sleep faster           |
| Standby transition                       | `standbydelayhigh` (default 24 h)  | `standbydelaylow` (default 3 h) when SOC > 50%   |
| Wake-on-network (Bonjour Sleep Proxy)    | Active                             | Disabled                                          |
| Wake-on-USB / Wake-on-Bluetooth          | Active                             | Mostly active; some peripherals gated by SOC      |
| Scheduled activities (CTS / DAS)         | Run during dark wakes              | Defer aggressively; many wait for AC              |
| Time Machine                             | Runs during dark wake              | Defers until AC                                   |
| Software Update download                 | Runs during dark wake              | Defers until AC                                   |
| Low Power Mode (macOS 12+)               | Cannot enable in Settings (no UI)  | User-toggleable; affects scheduling               |
| `NSBackgroundActivityScheduler` firings  | Roughly on schedule                | Coalesced harder, deferred further                |

**What is not different (or less different than assumed):**

- **Intermediate dark wakes happen on battery too.** Field-incident
  data (see §3) captured 31 dark wakes across a 73-minute battery
  sleep — almost identical to AC behaviour. Whatever the kernel is
  doing every couple of minutes (thermal sampling, ARP refresh,
  timer fan-out) it does on both power sources.
- **IOKit goes silent for dark wake on both.** Per Apple DTS
  (§2.7), `kIOMessageSystemHasPoweredOn` is intentionally not
  delivered for dark wake regardless of power source. The visibility
  gap is identical.
- **`SuspendingClock` semantics are identical.** The clock pauses
  when the CPU is suspended, full stop. The drift detector
  (§2.3) fires the same way on both.
- **`willSleep` / `didWake` notification fidelity is identical.**
  Both fire on full user sleep/wake on both power sources; both stay
  silent across dark wake on both.

**Practical consequence for a supervisor daemon:**

You do *not* need separate code paths for AC vs battery. The clocks,
notifications, and grace logic that work on AC work on battery. Where
adaptation matters is policy, not mechanism:

- **Poll interval** — sensible to lengthen on battery (longer
  intervals coalesce harder with the existing dark-wake cadence; see
  §2.11 for the signals to observe and §4.12 for the wreaper
  implementation).
- **Discretionary work** — defer when on battery, particularly under
  Low Power Mode (`isLowPowerModeEnabled`).
- **Thermal sensitivity** — battery sleep with the lid closed is
  thermally generous; AC sleep with the machine charging can run
  warm enough that the daemon should back off harder under
  `thermalState == .serious`.

**A note on standby:** after `standbydelaylow`/`high`, the machine
transitions to a deeper sleep that suppresses most dark wakes. On
Apple Silicon this is reached quickly (often within an hour on
battery); on Intel it takes longer but is closer to "fully off". A
daemon that depends on dark-wake CPU time (e.g. for cron-style work)
will see that time disappear after standby. The right design is to
not depend on it: `NSBackgroundActivityScheduler` and
`StartCalendarInterval` both handle standby correctly because the
system wakes itself to fire them; hand-rolled timers do not.

### 2.28 Stable code-sign identifier

TCC keys on code-signing identity, not bundle path. A daemon that's
re-signed with a different team ID *or* a different identifier loses
its grants. For local development:

```bash
codesign --force --sign - --identifier com.example.daemon /usr/local/bin/your-daemon
```

The `--identifier` flag pins the TCC key across ad-hoc rebuilds. For
release, sign with a Developer ID and a *fixed* identifier that
never changes across versions. Wrap this in a project script and
invoke it from every local build — losing the AX (or any TCC) grant
on every rebuild is a 30-minute productivity loss per rebuild and
well worth the scripting.

### 2.29 What fires when — consolidated reference matrix

The single most useful piece of information for triaging
sleep/wake behaviour: which APIs fire (✓) and which stay silent (·)
for each macOS power transition.

| Transition                              | `willSleep` | `didWake` | `screensDidSleep` | `screensDidWake` | IOKit `WillSleep` / `CanSleep` | IOKit `HasPoweredOn` | IOKit `WillPowerOn` | `SuspendingClock` pauses | `ContinuousClock` pauses |
|-----------------------------------------|:-----------:|:---------:|:-----------------:|:----------------:|:------------------------------:|:--------------------:|:-------------------:|:------------------------:|:------------------------:|
| Full user sleep (lid close, Sleep menu) | ✓           | ·         | sometimes         | ·                | ✓                              | ·                    | ·                   | (begins)                 | no                       |
| Full user wake                          | ·           | ✓         | ·                 | ✓                | ·                              | ✓                    | ✓ (precedes HasPoweredOn) | (resumes)            | (kept running)           |
| Display sleep only (no CPU sleep)       | ·           | ·         | ✓                 | ·                | ·                              | ·                    | ·                   | no                       | no                       |
| Display wake only                       | ·           | ·         | ·                 | ✓                | ·                              | ·                    | ·                   | no                       | no                       |
| Dark wake (Power Nap / maintenance)     | ·           | ·         | ·                 | ·                | ·                              | · *                  | · *                 | (resumes briefly)        | (kept running)           |
| Return to sleep after dark wake         | ·           | ·         | ·                 | ·                | · *                            | ·                    | ·                   | (pauses again)           | no                       |
| Standby transition (after `standbydelay`)| ·          | ·         | ·                 | ·                | ·                              | ·                    | ·                   | (already paused)         | no                       |
| Wake from standby                       | ·           | ✓         | ·                 | ✓                | ·                              | ✓                    | ✓                   | (resumes)                | (kept running)           |
| User clock change                       | ·           | ·         | ·                 | ·                | ·                              | ·                    | ·                   | no                       | no                       |
| NTP slew                                | ·           | ·         | ·                 | ·                | ·                              | ·                    | ·                   | no                       | no                       |

\* IOKit *intentionally* suppresses these for dark wake per Apple
DTS — see §2.7. Some dark wakes deliver `WillPowerOn` but not
`HasPoweredOn`; some deliver neither. This is the visibility gap
that makes the `SuspendingClock`/`ContinuousClock` drift detector
load-bearing.

Reading the matrix:

- **No single API row is complete.** Every column has cases where it
  is silent for a real transition. That is the design justification
  for the layered-observer pattern in §2.8.
- **The two clocks together produce information no notification API
  provides.** When `SuspendingClock` advances slower than
  `ContinuousClock` between two ticks, the machine was suspended in
  between, regardless of which notifications fired or didn't.
- **`willSleep`/`didWake` are full-wake only.** Designing around the
  assumption that they always pair with the corresponding IOKit
  message is unsafe — see incident pattern #7 in
  [`sleep-wake-log-guide.md`](sleep-wake-log-guide.md).

### 2.30 POSIX `sleep()` / `nanosleep()` pause across system sleep

A subtle correctness issue that bites code ported from Linux. On
Linux, `sleep(N)` uses `CLOCK_MONOTONIC`, which continues advancing
across system suspend, so a 10-second sleep across a 1-hour suspend
returns roughly on time. **On macOS, `nanosleep()` (and therefore
`sleep()`, `usleep()`, `Thread.sleep(forTimeInterval:)`) use
`CLOCK_UPTIME_RAW` semantics — they pause during system sleep**.

```swift
// On macOS, this returns ~5 s of CPU-active time, possibly hours
// of wallclock time if the machine slept in the middle:
Thread.sleep(forTimeInterval: 5)
```

Swift Concurrency's `Task.sleep` is explicit about which clock:

```swift
try await Task.sleep(for: .seconds(5))                 // ContinuousClock (default) — does NOT pause
try await Task.sleep(for: .seconds(5), clock: .suspending)  // SuspendingClock — pauses
```

The defaulting behaviour flipped between Swift versions; never rely
on the default — always pass the clock explicitly. For a supervisor
daemon, the choice mirrors §2.3: timeouts that should "feel like
user-visible time" are `.suspending`; deadlines that should "feel
like wall-clock time" are `.continuous`.

Also: `DispatchQueue.asyncAfter(deadline:)` uses `DISPATCH_TIME_NOW`
which is mach absolute time — pauses across sleep. `asyncAfter(wallDeadline:)`
uses wall time — does *not* pause. Mixing these up is one of the
more common sleep-related bugs.

### 2.31 The modern process-state stack: `runningboardd`

Since macOS Catalina, process state is coordinated by
`runningboardd`, not `launchd` alone. `runningboardd` owns:

- App Nap eligibility decisions
- Process suspend/resume across thermal pressure
- Assertion tracking (`ProcessInfo.beginActivity` flows through it)
- The "blame attribution" surfaced in `pmset -g assertions`

Practical implications:

- **`launchctl print gui/$UID/<label>` includes `runningboardd`
  state**, not just launchd state. Look for `assertions:` and
  `endpoints:` sections. A daemon that's holding a stale assertion
  shows up here.
- **`rbs` is `runningboardd`'s private SPI** — there are no public
  bindings. Don't try to call into it. The public surface is
  `ProcessInfo.beginActivity` + `IOPMAssertion`; everything else
  flows through those.
- **Crashes in `runningboardd` are catastrophic** — the system
  becomes unable to coordinate process state and typically restarts
  itself. If a daemon's behaviour changes wildly after an OS update,
  `runningboardd` log noise is the first thing to grep for:
  `log show --predicate 'subsystem == "com.apple.runningboard"'`.

### 2.32 Background Task Management UI (macOS Ventura+)

Since Ventura, *every* installed LaunchAgent and LaunchDaemon appears
in System Settings → General → Login Items & Extensions → "Allow in
the Background". Users can disable yours, and **there is no
notification API** to inform the daemon that it was disabled. The
only signal is that it stops launching.

Mitigations:

- Surface the install state explicitly in a diagnostic command
  (`launchctl print gui/$UID/<label>` reports enabled state).
- Document the path users navigate to re-enable the agent.
- Treat "daemon not running but should be" as a recoverable state
  — instructions in the diagnose output, not silent failure.

The same UI surfaces "Background Task Management" notifications when
a new LaunchAgent is registered. Users see "*<label>* added a login
item" with no context; choose a label that is self-explanatory
(`com.example.daemon-name`) rather than an internal codename.

### 2.33 Memory pressure across sleep and standby

During standby, macOS aggressively compresses memory and may page
out anonymous memory to disk. On wake:

- Page-in latency can stall the first tick by hundreds of
  milliseconds to seconds. Cosmetically this looks like "the daemon
  is hung" in `spindump` but is just paging.
- `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`
  fires when the system asks for memory back. Long-lived daemons
  with caches should respond by dropping cached state.
- macOS does not jetsam-kill user-process daemons under memory
  pressure the way iOS does, but it will defer their CPU scheduling
  aggressively until pressure clears.

For a periodic supervisor, the practical advice is: keep the
working set small (no large in-memory caches), drop any optional
state on `.warning`, and don't be surprised when the first
post-wake tick is slower than steady-state.

### 2.34 Lid state and clamshell mode

`IOPMrootDomain` exposes `AppleClamshellState` (boolean) and
`AppleClamshellCausesSleep`. Three operating modes:

- **Lid open, no external display** — normal. Sleep on idle timer
  or Sleep menu.
- **Lid closed, no external display** — immediate sleep on lid
  close regardless of activity.
- **Lid closed *with* external display** (clamshell mode) — the
  machine *does not sleep*. CPU runs at full power, all observers
  remain active, `SuspendingClock` keeps advancing.

A daemon that assumes "lid closed → going to sleep soon" is wrong
in the third case. The clamshell-mode-with-external-display
configuration is common on developer desks (laptop-as-desktop) and
produces a workload pattern more like a Mac Studio than a MacBook:
no sleep at all for days.

`IOServiceAddInterestNotification` on `IOPMrootDomain` can monitor
clamshell transitions, but for most daemons the right behaviour is
*not* to care — the existing sleep/wake observers cover the
behaviour that matters (whether the CPU is suspended), and the lid
state is downstream noise.

### 2.35 Sandboxed apps and the hardened runtime

App Store distribution and Notarisation impose constraints worth
knowing about up-front:

- **App Sandbox blocks most direct IOKit access.** A sandboxed
  process cannot open `IOServiceMatching("IOPMrootDomain")` or call
  `IORegisterForSystemPower`. `NSWorkspace.notificationCenter` keeps
  working (it goes through `runningboardd`), as do
  `NSBackgroundActivityScheduler` and `ProcessInfo.beginActivity`.
  If your design depends on IOKit power messages, you are
  necessarily outside the sandbox — plan distribution accordingly.
- **The hardened runtime is orthogonal to the sandbox.** It
  restricts unsigned dylibs, JIT, etc., but does not change which
  power APIs are reachable. Notarisation requires the hardened
  runtime; both leave IOKit unaffected.
- **TCC purposes have separate sandbox containers.**
  `com.apple.security.personal-information.accessibility`,
  `com.apple.security.device.audio-input`, etc. are independent;
  granting one does not grant another. The §2.26 wake re-check
  must run per purpose.
- **For an App-Store-distributed daemon**, prefer
  `NSBackgroundActivityScheduler` (§2.4) and the `NSWorkspace`
  observers (§2.8). Skip IOKit; you cannot use it anyway. The
  clock-drift detector (§2.3) still works inside the sandbox.

### 2.36 Headless and SSH-only Macs

A Mac with no logged-in user (CI runner, server, remote dev box
over SSH) has no `loginwindow` session, which means:

- **No `NSWorkspace` notifications.** They are delivered to the
  per-user `NSWorkspace.shared.notificationCenter` and only fire
  inside a GUI session.
- **A LaunchAgent will not load.** LaunchAgents bind to
  `gui/<UID>`; without a `gui/` domain, `launchctl bootstrap` fails.
  Use a LaunchDaemon (`system/`) instead.
- **AppKit-only APIs are inaccessible.** `NSWorkspace`, AX, anything
  requiring `NSApplication`. IOKit, `ProcessInfo`,
  `NSBackgroundActivityScheduler` all work fine in a LaunchDaemon.
- **Display-related state is moot.** `screensDidSleep` etc. never
  fire (there's no logged-in display server). Trust `IOKit`
  power messages and the clock-drift detector.

For a tool that must work both in-session and headless, the
cleanest pattern is to make `NSWorkspace` observation *optional*:
register if `NSWorkspace.shared.runningApplications` is non-empty,
otherwise fall back to IOKit-only. Many ostensibly cross-mode tools
ship as LaunchAgent + LaunchDaemon pair, with the daemon delegating
session-dependent work to the agent over XPC.

### 2.37 MenuBar apps as supervisors

A common alternative to LaunchAgent + CLI is a single `LSUIElement`
AppKit app that sits in the menu bar. The trade-offs:

| Aspect                    | LaunchAgent + CLI                          | `LSUIElement` MenuBar app                          |
|---------------------------|--------------------------------------------|----------------------------------------------------|
| Lifecycle                 | `launchd` supervises; survives crashes     | User-launched; quits with logout                   |
| User affordance           | Invisible; requires CLI to query/control   | Always-visible icon + menu                         |
| Settings UI               | Config file or extra CLI commands          | Native `Settings` scene                            |
| Distribution              | Homebrew, manual install, MDM              | App Store (with sandbox constraints, §2.35), DMG  |
| Sleep observation         | Identical mechanisms — both can use the full §2.8 stack             |
| TCC prompt UX             | First eviction may prompt during sleep     | Prompts on launch with user present                |
| Footprint                 | ~5–20 MB resident                          | ~50–150 MB resident (AppKit, dock connection)      |

A MenuBar app *is* a long-running daemon — it has the same sleep
correctness obligations. The temptation to skip §§2.13–2.20
because "it's just a menu bar app" is the most common bug pattern
in this category. The `LSUIElement` plist key suppresses the dock
tile but does not change any sleep/wake semantics.

If you choose MenuBar, the install vehicle is "Login Item" rather
than LaunchAgent; macOS Ventura+ surfaces it in the same
Background Task Management UI (§2.32) and the same disable
caveats apply.

### 2.38 `pmset` parameters worth tuning (and not)

`pmset` exposes ~30 knobs. Most of them daemons should leave alone;
a few are worth knowing about because users may set them, changing
your operating environment.

**Daemons should never recommend users change these:**

- `standbydelaylow` / `standbydelayhigh` — controls when the
  machine transitions to standby. Shortening these can hurt
  battery; lengthening them defeats the standby design. If your
  daemon needs to run during standby, fix the daemon (BAS or
  `StartCalendarInterval`), not the system policy.
- `tcpkeepalive` — controls whether the kernel maintains TCP
  keepalive across sleep. Off-by-default on battery; users who
  need it usually already know. Daemons that depend on it have
  worse bugs than this knob can paper over.
- `hibernatemode` — Intel-era; mostly irrelevant on Apple Silicon.
  Modifying it has caused boot-loop incidents.

**Knobs worth *reading* because users sometimes flip them:**

- `darkwakes` — `1` enables dark wakes, `0` disables. Off means
  no Power Nap behaviour at all. If a daemon's diagnostics say
  "no dark wakes observed in 24h", `pmset -g | grep darkwakes`
  is the first thing to check.
- `powernap` — separate from `darkwakes`. On Apple Silicon
  effectively always 1.
- `lidwake` / `acwake` — auto-wake on lid open / AC plug-in.
  Users disable these for desk setups; affects when `didWake`
  fires.
- `sleep` / `displaysleep` — the user's idle-sleep timers. A
  daemon that exhibits "I never see a sleep" symptom often turns
  out to be running on a machine with `sleep 0`.

`pmset -g` (no args) dumps the current settings; `pmset -g custom`
shows the AC/battery split. Daemon diagnostic commands should
include both verbatim.

### 2.39 What this doc deliberately does not cover

To set scope expectations:

- **iOS / iPadOS background execution.** Different model (BGTask
  framework, finite execution windows, suspension instead of sleep).
  Some primitives have the same name (`SuspendingClock`) but the
  surrounding lifecycle is incompatible.
- **Driver-level (DriverKit) power management.** Kexts and
  DriverKit drivers participate in IOKit's power tree via
  `joinPMtree` / `setPowerState`; that is its own world and not the
  same surface as user-space `IORegisterForSystemPower`.
- **Time-critical real-time work** (audio, video capture). These
  have their own thread/priority story
  (`mach_msg_trap`, `thread_policy_set` with
  `THREAD_TIME_CONSTRAINT_POLICY`). Sleep correctness is the same
  but performance tuning is not addressed here.

---

## 3. The specific gap that bit wreaper

The 2026-05-13 incidents documented in
[`sleep-wake-log-guide.md`](sleep-wake-log-guide.md) — IOKit silent
across a 68-minute AC sleep, then again across a 73-minute battery
sleep with 31 intermediate dark wakes — match Apple's DTS guidance
*exactly*: dark wake is not supposed to be visible to user-space, and
`kIOMessageSystemHasPoweredOn` is intentionally suppressed for it.
The drift detector caught every one; correctness held.

What this means in practice:

- The current IOKit observer is doing all the job IOKit can do; the
  silent intervals are a property of macOS, not a bug we can fix.
- The clock-drift backstop is **load-bearing**, not redundant. Any
  refactor that removes it on the grounds of "the kernel will tell us"
  will regress reliability.
- Adding handling for `kIOMessageSystemWillPowerOn` (0xE000_0320) is
  cheap and recovers visibility on the subset of dark wakes that do
  emit that earlier message.
- Logging the unknown `messageType` values in the IOKit handler's
  `default` branch is a free diagnostic — without it we can't tell
  "IOKit silent" from "we filtered useful messages out".

---

## 4. App-specific status for `wreaper`

This section was originally a remediation backlog. Almost every item
on that backlog has shipped; the §4.x numbering is preserved as a
stable anchor for source-code cross-references (`StateTracker.swift`,
`Checkpointer.swift`, etc.). Each subsection now reads as
"implemented — see X" with the code anchor inline, rather than as a
recommendation. New refinements that did not appear on the original
backlog live in §§4.17–4.22.

### 4.1 Already correct — keep doing this

- **`SuspendingClock` for all timeouts.** Pause-on-sleep matches user
  intent ("3 minutes windowless" = 3 minutes of user-visible time).
- **`ContinuousClock`-vs-`SuspendingClock` drift detector.** The
  only signal that catches dark wake on either power source — see
  `detectImplicitWake` in `ReaperEngine.swift`. Per Apple DTS this
  is the supported workaround, not a hack.
- **Layered sleep/wake observation.** `CompositeSleepWakeObserver`
  ORs the `NSWorkspace` and IOKit observers; each child also exposes
  a level-triggered `isAsleep()` flag the engine queries at tick
  start. See §4.19 for the all-children-must-report invariant.
- **`NSWorkspace.screensDidSleep/Wake` gate on the outer loop.** The
  outer run loop (`ReaperEngine.run`) suspends the tick stream when
  the display is off — see §4.17 for the stronger willSleep teardown
  that builds on this.
- **`IOAllowPowerChange` on `CanSystemSleep` / `WillSleep`.**
  Acknowledged promptly in `IOKitSleepWake.handleMessage` — no 30 s
  stall.

### 4.2 `kIOMessageSystemWillPowerOn` is handled (implemented)

`IOKitSleepWake.handleMessage` arms the grace bit on both
`willPowerOn` and `hasPoweredOn`, idempotent via `consumeGraceTick`.
Recovers visibility on dark-wake-adjacent transitions where only
`WillPowerOn` fires. When `hasPoweredOn` arrives while the observer
is still flagged asleep (i.e. `willPowerOn` was missed) the path
logs a warning.

### 4.3 Unknown IOKit `messageType` is logged (implemented)

`IOKitPowerMessage.decode` returns `.unknown(rawType:)` for any
unrecognised IOKit message, and the handler logs the raw hex
constant at notice level rather than silently discarding it.
Distinguishes "IOKit told us nothing" from "we threw the message
away" without further code change.

### 4.4 Adaptive grace ticks from the drift detector (still open)

The drift detector currently drops exactly one tick on implicit
wake (`detectImplicitWake` in `ReaperEngine.swift`). After
multi-minute suspensions the AX subsystem can take longer than one
tick to repopulate window lists (§2.20). The intended refinement is
to arm N grace ticks where N scales with the observed wall delta —
e.g. one extra grace tick per 60 s of `wall +X`, capped at 3 —
preserving the single-skip behaviour for sub-minute dark wakes
while protecting against eviction races after a real sleep. The
synthetic-drift harness (§4.13) is the right test substrate; the
policy choice (60 s per grace, cap 3) needs at least one field run
to validate before becoming default.

### 4.5 `beginActivity(options: .background)` wraps the run loop (implemented)

`ReaperEngine.run` (around `ReaperEngine.swift:142`) wraps the loop
in `ProcessInfo.processInfo.beginActivity(options: [.background], …)`
with `endActivity` in a `defer`. No `.idleSystemSleepDisabled`, no
`.userInitiated` — the loop cooperates with App Nap rather than
fighting it. The supervisor is idle the vast majority of the time
and benefits from App Nap rather than wanting to escape it.

### 4.6 No stray `IOPMAssertion` (regression test in place)

`PowerAssertionsTests` pins the invariant: running `wreaper run`
must never produce a `pmset -g assertions` entry naming our
process. Guards against future refactors that wrap a code path in
`IOPMAssertionCreateWithName`.

### 4.7 Timer leeway on the tick stream (implemented)

The production `Clock` returns a `DispatchSourceTimer`-backed
tick stream with 10% leeway (see `Clock.swift`). The drift
detector and grace logic absorb the slip with no behavioural
change, and the kernel can coalesce the timer with neighbouring
process wakeups. See §4.17 for the stronger willSleep teardown
that eliminates wakeups entirely while asleep.

### 4.8 `NSBackgroundActivityScheduler` for `wreaper clear` (still open)

`wreaper clear` is exactly the workload BAS exists for:
discretionary, idempotent, no exact-time requirement, must not run
during dark wake. The cron-driven `StartCalendarInterval` model
currently shipped is correct, but a BAS-scheduled in-daemon sweep
would let the OS pick firing instants and avoid every cron-vs-sleep
race the field logs have shown. Two open questions before this
becomes a recommendation:

- BAS interval/tolerance behaviour after a long sleep — does it
  catch up with one immediate firing, or skip the missed window?
- BAS scheduling-state durability when the host process is a
  LaunchAgent that lives the entire user session.

### 4.9 SleepBugGate (historical)

`SleepBugGate` was a temporary refusal to install the LaunchAgent
until sleep handling was reliable. It was removed alongside the
`kIOMessageSystemWillPowerOn` fix and the drift-detector validation
tests, which together replaced the gate with code that demonstrates
correctness rather than refusing to run until it is established.
The analysis that informed the gate is preserved in
`docs/sleep-bug-repro.md` for archaeological reference.

### 4.10 Post-skip eviction regression tests (implemented)

The P1 signal-ordering and P2 process-abandonment regression tests
(see `Tests/WindowlessReaperCoreTests/`) cover the multi-stage
"wake → grace → next tick" sequence and pin that an app whose AX
snapshot is merely stale across a grace skip is not evicted. The
synthetic-drift seam in §4.13 is the substrate; the
`AXTrustRevocationTests` and `IdempotentEvictionTests` files exercise
the surrounding gates.

### 4.11 Pre-sleep `StateTracker` checkpoint (implemented)

`Checkpointer` (file: `Sources/WindowlessReaperCore/Engine/Checkpointer.swift`)
writes a `TrackerSnapshot` to
`~/Library/Application Support/windowless-reaper/state.json` via
`Data.write(to:options:.atomic)`.
`ReaperEngine+WakeObservers.startCheckpointOnSleep` subscribes to
`willSleepNotification` and calls `flushCheckpoint(reason: "willSleep")`
on every arrival. The shutdown path also flushes a final checkpoint
(`flushCheckpoint(reason: "shutdown")`) for paths where `willSleep`
never fires (launchd `bootout`, SIGTERM during awake state).

Snapshots persist durations, not instants (per §2.18) so reload
remains meaningful after a long suspension. Missing, corrupt, or
unknown-schema checkpoints fall back to `t=0` with a warning —
never crash. The `DecisionRing` is persisted in the same snapshot;
`wreaper diagnose` reads it.

### 4.12 Adaptive poll interval under battery / LPM / thermal (implemented)

`PowerPressureObserver` (file:
`Sources/WindowlessReaperCore/Engine/PowerPressureObserver.swift` and
its `+System` extension) exposes a `PressureSnapshot` with `source`
(AC vs battery), `lowPowerMode`, and `thermalState` fields.

- `ReaperEngine.effectiveInterval` (around `ReaperEngine.swift:198`)
  doubles the base interval when on battery or in Low Power Mode.
- `ReaperEngine.dispatchEvictions` (file:
  `ReaperEngine+SideEffects.swift`) *pauses eviction* (not
  observation) when `thermalState` is `.serious` or `.critical` —
  the tick loop continues to enumerate and decide, but no
  `terminate()` is issued.

The whole subsystem is gated by `[settings].adaptive_pressure`
(default off until field-tested per the original recommendation).
`AdaptivePressureTests` exercises each branch in isolation.

### 4.13 Synthetic-drift test harness (implemented)

`ImplicitWakeDetectionTests` advances the test `Clock`'s
`ContinuousClock` while pinning `SuspendingClock`, then asserts
`tick()` returns no decisions and logs `implicit wake detected`.
The injectable `Clock` seam (`now()` / `continuousNow()`) is the
same surface §4.4's adaptive-grace policy will test against.

### 4.14 SIGTERM/SIGINT handler for `wreaper run` (implemented)

`installSignalHandlers` in `Sources/wreaper/Commands/RunCommand.swift`
installs `SIG_IGN` and creates dispatch sources for SIGINT and
SIGTERM *before* publishing the cancel target. This eliminates the
window where an early signal could fire the handler before the
engine task is reachable — see the commit-history note on the
`cancel-target race in signal handler install` fix. Combined with
the §4.11 shutdown flush, a `launchctl bootout` cleanly checkpoints
state before the 20 s SIGKILL fallback.

### 4.15 AX trust re-check on every wake (implemented)

`ReaperEngine+WakeObservers.startAXTrustCheckOnWake` subscribes to
`didWakeNotification` and calls `AXIsProcessTrustedWithOptions(nil)`
via the engine's `PermissionProbe`. The result flows to
`updateAccessibilityRevoked(_:)` on the engine actor, which sets the
`accessibilityRevoked` flag.

Effect: while revoked, `dispatchEvictions` short-circuits with a
log notice ("AX trust revoked") and no `terminate()` runs. The
tick loop continues to enumerate, inspect, and decide — diagnostics
stay accurate. The most common trigger is a Homebrew upgrade
replacing the signed binary while the daemon was asleep.
`AXTrustRevocationTests` covers the flag flip.

### 4.16 Idempotent eviction across restart (implemented)

`StateTracker.beginEviction` stages a `cooldown` for the bundle
*before* the terminator runs.
`ReaperEngine+SideEffects.performEvictions` batches every staged
cooldown across the eviction list, then issues a single
`flushCheckpoint(reason: "preEvict")` barrier. After the barrier,
each `terminate()` call runs; a vetoed kill triggers
`StateTracker.vetoEviction` and an immediate
`flushCheckpoint(reason: "vetoRollback")` so the rollback is itself
durable.

Crash between barrier and kill leaves a too-long cooldown for any
un-killed bundle — safe direction, the bundle is skipped until the
cooldown expires and is never re-killed. The §4.17 batched-barrier
detail is what makes this invariant cheap enough to be default
behaviour. `IdempotentEvictionTests` pins the "cooldown durable
before kill" contract.

### 4.17 Tick stream torn down on `willSleep` (implemented)

`ReaperEngine.runVisibleEpoch` races the tick loop against the
sleep/wake transition stream. A `systemAsleep` arrival cancels the
task group and exits the visible epoch *before* the next tick fires;
the outer `run` loop then parks on `waitUntilAwake()` with no timer
armed. Net effect: zero scheduled wakeups across system sleep,
including dark wakes — strictly stronger than the §4.7 timer leeway,
which only reduces (not eliminates) dark-wake CPU exposure. The two
layers compose: leeway helps when the screen is on but the user is
idle; teardown handles the "screen off, kernel might dark-wake us"
case.

### 4.18 Coalesced pre-evict checkpoint barrier (implemented)

Earlier designs flushed a checkpoint per bundle inside the eviction
loop, which made §4.16's "cooldown durable before kill" expensive
enough to discourage adoption. The current implementation
(`performEvictions` in `ReaperEngine+SideEffects.swift`) stages all
cooldowns across the whole batch into the tracker, then issues a
*single* `flushCheckpoint(reason: "preEvict")`. The "durable before
kill" invariant holds for every bundle via one fsync, with no
interleaving in which a later bundle's kill could precede an
earlier bundle's cooldown reaching disk. This is the implementation
detail that makes §4.16 cheap enough to be default.

### 4.19 Composite observer waits for all children before emitting (implemented)

An earlier version of the composite observer emitted a transition
the moment *any* child reported, then took its sleep/wake value
from that single child. This produced spurious "awake" transitions
when one observer was faster than another to register the wake —
the engine could resume ticking while the other observer still
considered the system asleep. The fix in
`CompositeSleepWakeObserver.transitions` seeds per-child state to
`nil`, withholds emission until every child has reported at least
once, and then emits only on changes to the aggregated value
(asleep if *any* child is asleep). IOKit and `NSWorkspace` have
measurably different wake latencies on real hardware — hundreds of
ms apart on Apple Silicon — and the engine's correctness depends
on consistent agreement, not first-to-fire.

### 4.20 AX inspection failure is `.unknown`, not evictable (implemented)

`WindowInspector.windowState(for:)` returns `WindowState.unknown`
(rather than `.windowless`) when AX returns an error — typically
the first tick or two after wake, before the AX subsystem has
fully recovered (§2.20). `.unknown` is treated as "no evidence
either way" and never advances the windowless timer or triggers
eviction. Without this gate, a flaky AX read inside the grace
window could evict an app that still has a window.

### 4.21 Runtime health counters and slow-operation instrumentation (implemented)

`RuntimeHealth` (file:
`Sources/WindowlessReaperCore/Diagnostics/RuntimeHealth.swift`)
accumulates per-skip-reason counters (`asleep`, `notVisible`,
`grace`, `implicitWake`) and per-tick decision counts.
`SlowOperationPolicy` wraps the enumerate/inspect and termination
phases of each tick; elapsed > threshold emits a structured
warning with per-bundle and per-pid counts. Together these give
`wreaper diagnose` enough signal to distinguish "the daemon is
genuinely idle" from "the daemon is doing work but slowly" without
needing `spindump` or `powermetrics`.

### 4.22 Defensive IOKit lifecycle (implemented)

Two related fixes:

- `IOKitSleepWake.deinit` precondition catches a dangling
  `IOServiceInterestCallback` pointer if a refactor ever forgets
  to call `IOServiceRemoveInterestNotification` before the observer
  is released. The callback runs with an unmanaged refcon; a
  use-after-free would be a kernel-callback crash that no amount of
  unit testing would catch.
- `SleepWakeObserver.start()` is idempotent. Calling it twice does
  not register a second `IORegisterForSystemPower` callback;
  calling `stop()` on an unstarted observer is a no-op. The engine
  exercises both paths under `runVisibleEpoch`'s task-group
  cancellation.

---

## 5. Antipatterns cheat-sheet

A flat list for code review and PR triage. If you find any of these
in a daemon's code, there is almost certainly a sleep-correctness
bug underneath. Cross-references point to the section that explains
the right pattern.

1. **`Date.now` for durations, deadlines, or cooldowns.** `Date`
   jumps backwards on NTP slew and user clock changes — use
   `SuspendingClock` or `ContinuousClock`. (§2.18)
2. **`Thread.sleep(forTimeInterval:)` or `usleep` for "wait N
   seconds".** Pauses across system sleep on macOS; semantically
   different from Linux. Use `Task.sleep(for:clock:)` with an
   explicit clock. (§2.30)
3. **`DispatchQueue.asyncAfter(wallDeadline:)` for code that
   should pause across sleep.** It uses wall time and keeps
   running. Use `asyncAfter(deadline:)` for sleep-pausing
   semantics. (§2.30)
4. **`try?` on a checkpoint or state-write.** Discards IO errors
   silently; the first user-reported corruption will have no log
   line. Use `do { try … } catch { logger.warning(…) }`. (§2.13)
5. **`KeepAlive=true` on a long-lived LaunchAgent.** Respawns on
   *every* exit including clean shutdown. Use the dict form
   (`SuccessfulExit=false, Crashed=true`). (§2.9)
6. **Holding `PreventSystemSleep` or `.idleSystemSleepDisabled`
   "just to be safe".** Defeats the entire energy goal of a
   background daemon. Use `.background` with no sleep-prevention
   bit set. (§2.5)
7. **`StartInterval` *and* an internal timer in the same agent.**
   Two competing clocks; the `StartInterval` one serialises
   awkwardly across sleep. Pick one — usually the in-process timer.
   (§2.9)
8. **An in-process heartbeat watchdog that kills on silence.** Fires
   on every overnight sleep. Use `SuspendingClock` for the
   heartbeat, or let `launchd` supervise. (§2.25)
9. **Treating the IOKit observer as the single source of truth for
   wake.** It is intentionally silent on dark wake. Add
   `NSWorkspace.didWake` *and* the clock-drift detector. (§§2.7,
   2.8)
10. **`NSWorkspace.didWake` as the single source of truth.** Misses
    dark wake entirely and fires only on full user wake. Same fix
    as #9. (§2.7)
11. **Heavy work inside the IOKit power callback.** Blocks the
    serial queue and stalls the sleep transition. Set a flag, post
    elsewhere, return. (§2.14)
12. **Polling without `leeway` / `tolerance`.** Forces a CPU wake
    that won't coalesce with any other process. 10% leeway is the
    minimum; more is better. (§2.2)
13. **A long-lived TCP/HTTP/WebSocket connection that doesn't reset
    on `didWake`.** Will hang on the first post-wake send (minutes).
    Reset on `NWPathMonitor` path changes. (§2.19)
14. **A fixed `Thread.sleep` after wake before querying AX/GPU/etc.**
    Either too short (queries fail) or too long (wastes battery).
    Use a per-subsystem readiness check / one retry. (§2.20)
15. **Logging user-visible data without `privacy: .public`.** Gets
    redacted in release builds; you discover this when triaging a
    user report. Annotate explicitly. (§2.22)
16. **Re-signing a daemon with a different `--identifier` between
    builds.** Loses every TCC grant. Pin the identifier; for
    release, sign with a stable Developer ID. (§2.28)
17. **Holding a TCC grant in a cached `Bool` for the lifetime of
    the process.** Grants can be revoked silently mid-run
    (Homebrew upgrade, OS update). Re-check on every `didWake`.
    (§2.26)
18. **Persisting `Date` instants instead of `Duration`s in
    checkpoints.** On reload the absolute instants are wrong if
    the user changed the clock or NTP slewed. Persist durations,
    re-anchor on load. (§2.18)
19. **Writing the checkpoint on every state mutation.** Burns IO
    and disk wakes for state that only matters at recovery time.
    Write on `willSleep` and on clean shutdown — that's it. (§2.13)
20. **Designing for "AC vs battery" as different code paths.** The
    mechanism (clocks, notifications, grace logic) is identical.
    *Policy* (poll interval, deferral) may adapt; mechanism does
    not. (§2.27)
21. **Branching on Apple Silicon vs Intel in production code.**
    Same answer as #20 — the visible behaviour is the same; only
    the rate/depth differs. Branch only in diagnostics if at all.
    (§2.15)
22. **A `LSUIElement` menu-bar app that skips sleep handling
    because "it's not a daemon".** It *is* a long-running process
    with the same obligations. The dock-suppression flag changes
    nothing about sleep semantics. (§2.37)
23. **Sandboxed app trying to use `IORegisterForSystemPower`.**
    Blocked by App Sandbox. Use `NSWorkspace` + clock-drift
    detector instead, or distribute outside the App Store. (§2.35)

---

## 6. References

- [Energy Efficiency Guide for Mac Apps: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- [Energy Efficiency Guide for Mac Apps: Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
- [Energy Efficiency Guide for Mac Apps: Schedule Background Activity](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html)
- [NSBackgroundActivityScheduler — Apple Developer Documentation](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler)
- [ProcessInfo.ActivityOptions — Apple Developer Documentation](https://developer.apple.com/documentation/foundation/processinfo/activityoptions)
- [SuspendingClock](https://developer.apple.com/documentation/swift/suspendingclock) and [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) reference, plus [SE-0329 (Clock, Instant, Duration)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md)
- [Apple Developer Forums thread 770517 — Detecting DarkWake and Maintenance Sleep](https://developer.apple.com/forums/thread/770517)
- [Apple Developer Forums thread 115114 — DispatchSourceTimer reliability under App Nap](https://developer.apple.com/forums/thread/115114)
- [Eclectic Light Co — How macOS schedules and dispatches background tasks (CTS, DAS)](https://eclecticlight.co/2020/10/15/how-macos-schedules-and-dispatches-background-tasks-using-cts-3/)
- `man pmset(1)` — authoritative reference for `pmset -g log`, `pmset -g assertions`, `pmset schedule`, and the `darkwakes` / `wakerequests` flags used in §2.10 and §2.16.
- `man caffeinate(8)` — flag reference for the reproduction commands in §2.16.
- `man powermetrics(1)` — sampler list (`tasks`, `cpu_power`, `gpu_power`, `network`, `disk`) used in §2.10.
- [IOPSCopyPowerSourcesInfo / IOPSNotificationCreateRunLoopSource — IOKit Power Sources reference](https://developer.apple.com/documentation/iokit/iopowersources_h)
- [ProcessInfo.ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate) and [isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/1617047-islowpowermodeenabled) — runtime pressure signals used in §2.11 and §4.12.
- Local: [`docs/sleep-wake-log-guide.md`](sleep-wake-log-guide.md) — log patterns, two recorded field incidents, and the remediation plan that this report extends.
