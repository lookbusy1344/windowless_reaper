import Foundation
import Logging

extension ReaperEngine {
    static func slowCounts(for snapshots: [AppSnapshot]) -> SlowOperationCounts {
        let appCount = snapshots.count
        let pidCount = snapshots.reduce(into: 0) { $0 += $1.windowStates.count }
        return SlowOperationCounts(appCount: appCount, pidCount: pidCount, windowCount: nil)
    }

    static func slowCounts(for apps: [RunningApp], snapshots: [AppSnapshot]) -> SlowOperationCounts {
        let appCount = apps.count
        let pidCount = apps.count
        let windowCount = snapshots.reduce(into: 0) { $0 += $1.windowStates.count }
        return SlowOperationCounts(appCount: appCount, pidCount: pidCount, windowCount: windowCount)
    }

    func buildSnapshots() async -> [AppSnapshot] {
        let start = ContinuousClock.now
        let apps = await enumerator.enumerate()
        let activeIDs = Set(config.rules.compactMap { $0.value.timeout != nil ? $0.key : nil })
        let filtered = apps.filter { activeIDs.contains($0.bundleID) }
        let grouped = Dictionary(grouping: filtered, by: { $0.bundleID })
        var snapshots: [AppSnapshot] = []
        snapshots.reserveCapacity(grouped.count)
        for (bundleID, runningApps) in grouped {
            var states: [pid_t: WindowState] = [:]
            for app in runningApps {
                states[app.pid] = await inspector.windowState(for: app.pid)
            }
            snapshots.append(AppSnapshot(bundleID: bundleID, windowStates: states))
        }
        if let warning = slowOperationPolicy.warning(
            phase: .inspection,
            elapsed: ContinuousClock.now - start,
            counts: Self.slowCounts(for: filtered, snapshots: snapshots)
        ) {
            logger.warning("\(slowOperationPolicy.render(warning))")
        }
        return snapshots
    }

    /// Filter `.evict` decisions through the thermal-pause and dry-run
    /// gates, then hand the survivors to `performEvictions` as one batch
    /// so they share a single pre-evict checkpoint barrier.
    func dispatchEvictions(decisions: [Decision], dryRun: Bool) async {
        // Thermal pause (§4.12): under serious/critical thermal pressure,
        // terminating apps adds load to an already-stressed system without
        // helping the user. Continue observing and logging so diagnostics
        // remain accurate; just skip the kill side of the tick body.
        let pressureSnap = pressure.snapshot()
        let thermalPause = config.settings.adaptivePressure
            && (pressureSnap.thermalState == .serious || pressureSnap.thermalState == .critical)
        let effectiveDryRun = dryRun || config.settings.dryRun
        let pauseReason = evictionPauseReason(thermalPause: thermalPause, snap: pressureSnap)
        var batch: [(bundleID: BundleID, pids: Set<pid_t>)] = []
        for decision in decisions {
            guard case .evict(let bundleID, let pids) = decision else { continue }
            if let reason = pauseReason {
                logger.notice("\(reason) — skipping eviction of \(bundleID.value) pids=\(pids.sorted())")
                continue
            }
            if effectiveDryRun {
                logger.notice("would terminate \(bundleID.value) pids=\(pids.sorted())")
                continue
            }
            batch.append((bundleID, pids))
        }
        if !batch.isEmpty { await performEvictions(batch) }
    }

    /// Idempotent eviction (§4.16): stage every cooldown in the batch
    /// and checkpoint *once* before any terminator call. A crash between
    /// the barrier flush and any kill leaves too-long cooldowns for the
    /// un-killed bundles (safe direction — they get skipped until the
    /// cooldown expires, never re-killed). A vetoed kill rolls back that
    /// bundle's cooldown to tracked and re-checkpoints immediately so the
    /// rollback survives a subsequent crash.
    ///
    /// Batching is strictly safer than the previous per-bundle flush: the
    /// "cooldown durable before kill" invariant holds for *every* bundle
    /// in the batch via a single fsync, with no interleaving in which a
    /// later bundle's kill could precede an earlier bundle's cooldown
    /// reaching disk.
    func performEvictions(_ groups: [(bundleID: BundleID, pids: Set<pid_t>)]) async {
        var staged: [(BundleID, Set<pid_t>)] = []
        staged.reserveCapacity(groups.count)
        for group in groups {
            let didStage = await tracker.beginEviction(
                bundleID: group.bundleID, now: clock.now(), config: config
            )
            if didStage { staged.append((group.bundleID, group.pids)) }
        }
        // Single durability barrier: every staged cooldown reaches disk
        // before the first terminator call.
        if !staged.isEmpty { await flushCheckpoint(reason: "preEvict") }

        let start = ContinuousClock.now
        var totalPids = 0
        for (bundleID, pids) in staged {
            totalPids += pids.count
            var allAccepted = true
            for pid in pids.sorted() {
                // PID-reuse TOCTOU: these pids were snapshotted in
                // buildSnapshots and could in theory be recycled before this
                // call. The window is sub-second and
                // NSRunningApplication(processIdentifier:) re-resolves,
                // returning nil (→ no-op) for a recycled non-app pid, so the
                // real-world risk is negligible — not worth defensive code.
                let accepted = await terminator.terminate(pid: pid)
                logger.debug("terminate \(bundleID.value) pid=\(pid) accepted=\(accepted)")
                if !accepted { allAccepted = false }
            }
            if allAccepted {
                logger.notice("terminated \(bundleID.value) pids=\(pids.sorted())")
            } else {
                await tracker.vetoEviction(bundleID: bundleID, now: clock.now(), config: config)
                await flushCheckpoint(reason: "vetoRollback")
                logger.warning("terminate request not delivered \(bundleID.value) (pid gone?) — timer reset")
            }
        }
        if let warning = slowOperationPolicy.warning(
            phase: .termination,
            elapsed: ContinuousClock.now - start,
            counts: SlowOperationCounts(appCount: staged.count, pidCount: totalPids, windowCount: nil)
        ) {
            logger.warning("\(slowOperationPolicy.render(warning))")
        }
    }
}
