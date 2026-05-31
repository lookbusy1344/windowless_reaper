import Foundation

/// What the engine should do this tick for a single bundle ID.
///
/// One decision is emitted per bundle that either has a rule and appears in
/// this tick's snapshot, or carries persistent state from a prior tick.
/// Bundles with neither (no rule, no state) produce no decision at all.
public enum Decision: Sendable, Equatable {
    /// No action. Either the bundle has visible/minimised windows, or its
    /// cooldown has just expired and the snapshot still shows windows.
    case ignore(BundleID)

    /// Bundle is being tracked as windowless. `since` is the original
    /// timestamp — unchanged from prior ticks once tracking has started
    /// (unless a config-driven re-anchor occurred).
    case track(BundleID, since: SuspendingClock.Instant)

    /// Timeout reached. Engine should call `terminate(pid:)` on every PID
    /// in `pids`, then call `StateTracker.recordTermination(...)` with the
    /// combined outcome.
    case evict(BundleID, pids: Set<pid_t>)

    /// Bundle is in post-termination cooldown until `until`. Even if the
    /// app relaunches and is windowless, we do not re-track until cooldown
    /// expires.
    case cooldown(BundleID, until: SuspendingClock.Instant)
}
