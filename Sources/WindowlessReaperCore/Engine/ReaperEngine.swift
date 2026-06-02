@preconcurrency import AppKit
import Foundation
import Logging

/// Wiring layer between I/O seams (enumerator, inspector, terminator,
/// clock, sleep/wake observers) and the pure `StateTracker`. One `tick()`:
/// consume wake grace → enumerate → inspect → group → decide → terminate
/// → record. Actor-isolated to serialise per-tick mutations.
public actor ReaperEngine {
    var config: Config
    var tracker: StateTracker
    let enumerator: any AppEnumerator
    let inspector: any WindowInspector
    let terminator: any Terminator
    let clock: any Clock
    let sleepWake: any SleepWakeObserver
    let powerState: any SystemPowerStateObserver
    let pressure: any PowerPressureObserver
    let checkpointer: (any Checkpointer)?
    let permissionProbe: (any PermissionProbe)?
    let logger: Logger
    let decisionRing: DecisionRing
    let diagnosticsSink: (any DiagnosticsSink)?
    let slowOperationPolicy = SlowOperationPolicy()
    var runtimeHealth = RuntimeHealth()
    /// True while AX trust is missing — see §4.15. Set by the wake task;
    /// gates evictions in `tick`. Decisions are still recorded.
    var accessibilityRevoked = false

    /// Continuous-vs-suspending drift above this is treated as implicit
    /// suspension (dark wake on AC); the engine skips one tick to avoid
    /// mass-evicting on stale counters. Well above scheduling jitter (sub-ms)
    /// and well below the minimum poll interval.
    static let implicitWakeDriftThreshold: Swift.Duration = .seconds(5)

    /// Cadence for emitting `runtime-health` log lines. One snapshot per
    /// wall-hour is enough to bound a 72hr soak log without drowning it.
    static let healthLogInterval: Swift.Duration = .seconds(3600)

    /// Last observed instants, used to detect implicit suspensions. Nil
    /// before the first tick — that tick has no baseline and runs normally.
    var lastTickSuspending: SuspendingClock.Instant?
    var lastTickContinuous: ContinuousClock.Instant?
    /// Suspending instant of the last `runtime-health` emission; nil until
    /// the first tick fires the baseline snapshot.
    var lastHealthLogSuspending: SuspendingClock.Instant?

    public init(
        config: Config,
        enumerator: any AppEnumerator,
        inspector: any WindowInspector,
        terminator: any Terminator,
        clock: any Clock,
        sleepWake: any SleepWakeObserver,
        powerState: any SystemPowerStateObserver,
        pressure: (any PowerPressureObserver)? = nil,
        checkpointer: (any Checkpointer)? = nil,
        permissionProbe: (any PermissionProbe)? = nil,
        logger: Logger = Logger(label: "wreaper.engine"),
        decisionRing: DecisionRing = DecisionRing(),
        diagnosticsSink: (any DiagnosticsSink)? = nil
    ) {
        self.config = config
        tracker = StateTracker()
        self.enumerator = enumerator
        self.inspector = inspector
        self.terminator = terminator
        self.clock = clock
        self.sleepWake = sleepWake
        self.powerState = powerState
        // Default to nominal pressure for callers that opt out of adaptive policy.
        self.pressure = pressure ?? StaticPressureObserver(.nominal)
        self.checkpointer = checkpointer
        self.permissionProbe = permissionProbe
        self.logger = logger
        self.decisionRing = decisionRing
        self.diagnosticsSink = diagnosticsSink
    }

    /// Updated by the wake-observation task in `startAXTrustCheckOnWake`.
    public func updateAccessibilityRevoked(_ revoked: Bool) {
        guard accessibilityRevoked != revoked else { return }
        accessibilityRevoked = revoked
        if revoked {
            logger.error("Accessibility trust lost on wake — evictions paused")
        } else {
            logger.notice("Accessibility trust restored — evictions resumed")
        }
    }

    public func isAccessibilityRevoked() -> Bool {
        accessibilityRevoked
    }

    /// Swap the active config. Rules removed from the new config cause their
    /// bundles to be untracked on the next `tick()` (see `StateTracker.tick`).
    public func updateConfig(_ newConfig: Config) {
        config = newConfig
        runtimeHealth.noteConfigUpdate()
    }

    /// Snapshot tracker state (durations, not instants) — §§2.18, 4.11.
    public func checkpointSnapshot() async -> TrackerSnapshot {
        await tracker.snapshot(now: clock.now())
    }

    /// Lightweight counters for long-run triage.
    public func runtimeHealthSnapshot() -> RuntimeHealthSnapshot {
        runtimeHealth.snapshot
    }

    /// Write the last-N decision ring and current health counters to the
    /// out-of-process diagnostics sidecar. Called at the end of every tick
    /// (including skipped ticks, whose health counters still advance).
    private func persistDiagnostics() async {
        guard let diagnosticsSink else { return }
        let decisions = await decisionRing.snapshot()
        await diagnosticsSink.write(decisions: decisions, health: runtimeHealth.snapshot)
    }

    /// Replace the tracker; call once on startup before the first tick.
    func restoreCheckpoint(_ snapshot: TrackerSnapshot) async {
        let now = await clock.now()
        tracker = StateTracker.restore(snapshot, now: now)
        logger.notice("checkpoint restored entries=\(snapshot.entries.count)")
    }

    /// Persist tracker state. No-op without a checkpointer; I/O failure
    /// logs only — the engine must not crash on checkpoint failure.
    public func flushCheckpoint(reason: String) async {
        guard let checkpointer else { return }
        let snapshot = await checkpointSnapshot()
        let start = ContinuousClock.now
        do {
            try await checkpointer.save(snapshot)
            logger.notice("checkpoint flushed reason=\(reason) entries=\(snapshot.entries.count)")
        } catch {
            runtimeHealth.noteCheckpointSaveFailure()
            logger.warning("checkpoint flush failed reason=\(reason): \(error)")
        }
        if let warning = slowOperationPolicy.warning(
            phase: .checkpoint,
            elapsed: ContinuousClock.now - start,
            counts: SlowOperationCounts(appCount: snapshot.entries.count, pidCount: snapshot.entries.count, windowCount: nil)
        ) {
            logger.warning("\(slowOperationPolicy.render(warning))")
        }
    }

    /// Drive the engine until cancelled. Two nested loops: outer suspends
    /// during dark-wake / display sleep; inner drives the tick stream and
    /// is rebuilt on `poll_interval` or effective-interval changes.
    public func run(dryRun: Bool = false) async {
        // The CLI override is monotonic by design: `--dry-run` cannot be
        // un-set by a config reload. The config-side flag is re-read every
        // tick (see `tick(dryRun:)`) so flipping `[settings].dry_run`
        // false → true → false via hot reload takes effect immediately.
        let cliDryRun = dryRun
        // .background hint per §4.5 — cooperates with App Nap; never
        // .idleSystemSleepDisabled (would block sleep) or .userInitiated.
        let activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.background],
            reason: "windowless-reaper supervisor loop"
        )
        defer { ProcessInfo.processInfo.endActivity(activityToken) }

        await powerState.start()
        await sleepWake.start()
        await pressure.start()

        // Restore the previous checkpoint *before* the first tick so per-bundle
        // elapsed-windowless state survives daemon restarts (§4.11). A missing
        // or corrupt checkpoint falls back to t=0 — never crash.
        if let checkpointer {
            if let restored = await checkpointer.load() {
                await restoreCheckpoint(restored)
            } else {
                logger.notice("no checkpoint found — starting from t=0")
            }
        }
        let willSleepTask = Self.startCheckpointOnSleep(engine: self)
        let wakeTrustTask = Self.startAXTrustCheckOnWake(engine: self, probe: permissionProbe)

        logger.notice(
            "run started pollInterval=\(config.settings.pollInterval) dryRun=\(cliDryRun || config.settings.dryRun)"
        )

        // Seed the start-of-run baseline (ticks=0) here, before any tick. The
        // in-loop emits then fire *after* each tick so a snapshot logged on
        // wake reflects the grace skip that tick consumed — otherwise the dump
        // lands between the eager skipped_asleep++ and the in-tick
        // skipped_grace++, showing grace one behind asleep.
        await emitHealthSnapshotIfDue(now: clock.now())

        while !Task.isCancelled {
            if await sleepWake.isAsleep() {
                runtimeHealth.noteSkip(.asleep)
                logger.notice("run suspended — system asleep")
                await waitUntilAwake()
                if Task.isCancelled { break }
                logger.notice("run resumed — system awake")
            }
            if !powerState.isUserVisible() {
                runtimeHealth.noteSkip(.notVisible)
                logger.notice("run suspended — awaiting user-visible state")
                await waitUntilVisible()
                if Task.isCancelled { break }
                logger.notice("run resumed — user-visible")
            }
            await runVisibleEpoch(cliDryRun: cliDryRun)
        }

        willSleepTask?.cancel()
        wakeTrustTask?.cancel()
        // Best-effort final flush — covers `launchctl bootout` / SIGTERM
        // paths where the willSleep notification never fires.
        await flushCheckpoint(reason: "shutdown")
        await sleepWake.stop()
        await powerState.stop()
        await pressure.stop()
        logger.notice("shutdown reason=cancel")
    }

    /// Adaptive policy from power_man_best_practices.md §4.12. Double the
    /// effective interval when on battery or in Low Power Mode; otherwise
    /// return the base. Thermal state does not change the interval — it
    /// gates eviction inside `tick(dryRun:)`.
    public static func effectiveInterval(_ base: Duration, snapshot: PressureSnapshot, adaptive: Bool) -> Duration {
        guard adaptive else { return base }
        if snapshot.lowPowerMode || snapshot.source == .battery {
            return Duration(seconds: base.seconds * 2)
        }
        return base
    }

    /// Run one tick. With `dryRun: true` (or `config.settings.dryRun`), the
    /// engine reports `.evict` decisions but never calls the terminator.
    @discardableResult
    public func tick(dryRun: Bool = false) async -> [Decision] {
        let suspending = await clock.now()
        let continuous = await clock.continuousNow()
        let tickStart = ContinuousClock.now
        var slowCounts = SlowOperationCounts.zero
        runtimeHealth.noteTick()
        // Update baseline on every exit path so a skipped tick does not bleed
        // its skipped interval into the next tick's drift computation.
        defer {
            lastTickSuspending = suspending
            lastTickContinuous = continuous
            if let warning = slowOperationPolicy.warning(
                phase: .tick,
                elapsed: ContinuousClock.now - tickStart,
                counts: slowCounts
            ) {
                logger.warning("\(slowOperationPolicy.render(warning))")
            }
        }

        if let reason = await shouldSkipTick(suspending: suspending, continuous: continuous) {
            runtimeHealth.noteSkip(reason)
            // Health counters advance on skipped ticks too — persist so the
            // sidecar reflects skips, not just decision-producing ticks.
            await persistDiagnostics()
            return []
        }

        let snapshots = await buildSnapshots()
        slowCounts = Self.slowCounts(for: snapshots)
        runtimeHealth.noteAXUnknownInspection(
            count: snapshots.reduce(into: 0) { total, snapshot in
                total += snapshot.windowStates.values.count(where: { $0 == .unknown })
            }
        )
        let now = suspending
        logger.debug("tick start snapshots=\(snapshots.count)")
        for snapshot in snapshots.sorted(by: { $0.bundleID.value < $1.bundleID.value }) {
            let pidStates = snapshot.windowStates
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            logger.debug("snapshot \(snapshot.bundleID.value) windowless=\(snapshot.isFullyWindowless) [\(pidStates)]")
        }

        let decisions = tracker.tick(now: now, snapshots: snapshots, config: config)
        for decision in decisions {
            logger.debug("decision \(Self.describe(decision, now: now))")
        }

        await dispatchEvictions(decisions: decisions, dryRun: dryRun)
        // The ring records intent — `.evict` is recorded even when the
        // terminator vetoed. Outcomes (accepted vs vetoed) are visible in
        // logs and reflected in the tracker's next-tick state.
        await decisionRing.recordAll(decisions)
        await persistDiagnostics()
        return decisions
    }

    // MARK: - Private

    func evictionPauseReason(thermalPause: Bool, snap: PressureSnapshot) -> String? {
        if accessibilityRevoked { return "AX trust revoked" }
        if thermalPause { return "thermal=\(snap.thermalState)" }
        return nil
    }

    private static func describe(_ decision: Decision, now: SuspendingClock.Instant) -> String {
        switch decision {
        case .ignore(let id):
            "ignore \(id.value)"
        case .track(let id, let since):
            "track \(id.value) elapsed=\(formatDuration(now - since))"
        case .evict(let id, let pids):
            "evict \(id.value) pids=\(pids.sorted())"
        case .cooldown(let id, let until):
            "cooldown \(id.value) remaining=\(formatDuration(until - now))"
        }
    }

    private static func formatDuration(_ d: Swift.Duration) -> String {
        let totalSeconds = max(0, Int(d.components.seconds))
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h\(m)m\(s)s" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }
}

/// Periodic emission of `RuntimeHealthSnapshot` to the log. The run loop
/// (not `tick()`) drives this so one-shot commands — `wreaper check`,
/// `wreaper clear` — that call `tick()` directly stay quiet. The first
/// call always emits — that baseline lets the soak log show an explicit
/// start-of-run counter set rather than inferring it from the next hour.
public extension ReaperEngine {
    func emitHealthSnapshotIfDue(now: SuspendingClock.Instant) {
        if let last = lastHealthLogSuspending, now - last < Self.healthLogInterval { return }
        lastHealthLogSuspending = now
        let s = runtimeHealth.snapshot
        logger.notice("""
        runtime-health ticks=\(s.ticks) \
        skipped_asleep=\(s.skippedAsleep) \
        skipped_not_visible=\(s.skippedNotVisible) \
        skipped_grace=\(s.skippedGrace) \
        skipped_implicit_wake=\(s.skippedImplicitWake) \
        config_updates=\(s.configUpdates) \
        ax_unknown_inspections=\(s.axUnknownInspections) \
        checkpoint_save_failures=\(s.checkpointSaveFailures)
        """)
    }
}

/// Pre-tick gates: order is isAsleep → isUserVisible → consumeGraceTick → drift.
/// Split from the main actor to keep tick() under cyclomatic budget.
private extension ReaperEngine {
    func shouldSkipTick(suspending: SuspendingClock.Instant, continuous: ContinuousClock.Instant) async -> RuntimeHealth.SkipReason? {
        if await sleepWake.isAsleep() { logger.debug("skipping tick — system asleep"); return .asleep }
        if !powerState.isUserVisible() { logger.debug("skipping tick — system not user-visible (dark wake / display sleep)"); return .notVisible }
        if await sleepWake.consumeGraceTick() { logger.notice("skipping tick after wake (grace period)"); return .grace }
        guard let lastS = lastTickSuspending, let lastC = lastTickContinuous else { return nil }
        let drift = (continuous - lastC) - (suspending - lastS)
        guard drift > Self.implicitWakeDriftThreshold else { return nil }
        logger.notice("skipping tick — implicit wake detected (wall +\(Self.formatDuration(continuous - lastC)), suspending +\(Self.formatDuration(suspending - lastS)))")
        return .implicitWake
    }
}
