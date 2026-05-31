# Test hangs — diagnosis, fix, prevention

Every `@Suite` carries `.timeLimit(.minutes(1))`. A hang surfaces as a
`timeLimitExceeded` failure on a named test; new suites must include
the trait — swift-testing has no global default, and 1 min is the
framework minimum.

## Loop-breaker — read first

If you arrived here because `swift test` returned exit code 124, output
stopped mid-run, or a test recorded `Time limit was exceeded`: **stop.
do not re-run blindly.** That reflex is what burns context and produces
no new information. Follow the procedure below; each retry without
diagnosis is wasted.

## What the failure looks like

- **`gtimeout` killed it** → exit code 124, log ends mid-test. Last
  `Test "…" started` line is the suspect.
- **`.timeLimit` fired** → `✘ Test "…" recorded an issue at FILE:LINE:
  Time limit was exceeded: 1 minute`. The named test *is* the hang;
  skip straight to "Common causes."

## Procedure when the trait didn't catch it

The trait covers `@Test` bodies. Hangs in test infra, `deinit`, or the
runner itself slip past.

1. Run bounded, with a backgrounded sampler so stacks land before the
   SIGKILL:

   ```bash
   mkdir -p /tmp/claude
   ( sleep 20 ; pgrep -f windowless-reaperPackageTests | head -1 \
       | xargs -I{} sample {} 3 -file /tmp/claude/stacks.txt ) &
   gtimeout 30 swift test --parallel 2>&1 | tee /tmp/claude/test.log
   ```

   If the run finishes cleanly the sampler hits a dead PID — harmless.

2. `tail -50 /tmp/claude/test.log` — last `Test "…" started` names the
   suspect. `head -30 /tmp/claude/stacks.txt` — the suspended Swift task
   shows what it's waiting on.

3. Re-run just that test serially to rule in/out a parallel-only race:

   ```bash
   gtimeout 30 swift test --num-workers 1 --filter "SuiteName/testName"
   ```

   If it passes serially but hangs under `--parallel`, the bug is
   shared mutable state (statics, fixed temp paths, a singleton actor),
   not the test logic. Hunt that, not the test body.

## Common causes in this codebase

- **Continuation leak.** `withCheckedContinuation` where one branch
  forgets to resume — usually a race between a termination handler and
  a timeout watcher. Fix: single phase lock with terminal states,
  exactly one resume per transition. See `SystemProcessRunner.run`.
- **Wrong clock.** `Task.sleep(for:)` on `ContinuousClock` advances
  during system sleep; `SuspendingClock` does not. Project rule:
  `SuspendingClock` for time comparisons that must survive sleep.
- **Pipe-drain deadlock.** A child writing >~64 KiB to a `Pipe` with
  no `readabilityHandler` blocks before exit; the termination handler
  never fires. Install a readability handler, clear it in the
  termination handler.
- **`@Suite(.serialized)` plus shared global state.** Two serialized
  suites contending on the same file/lock will hang one. Use per-test
  temp dirs.

## Do not "fix" by

- Raising `.timeLimit(.minutes(N))` to make the failure go away. The
  trait is the diagnostic; the bug is the hang.
- Adding `.disabled(…)` to skip the failing test.
- Annotating shared state `@unchecked Sendable` to silence the race
  the timeout exposed.

## Prevention

- `.timeLimit(.minutes(1))` on every new `@Suite` — cascades to every
  `@Test` it contains.
- Tests that create a `Process` pass a `timeout:` to the runner; never
  `waitUntilExit()` directly.
- Tests touching `withCheckedContinuation` assert explicitly that the
  continuation resumed — `.timeLimit` is the backstop, not the check.
