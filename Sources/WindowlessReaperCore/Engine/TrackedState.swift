/// Per-bundle internal state held by the `StateTracker`.
///
/// Absent from the tracker's dictionary == UNTRACKED. Only the two persistent
/// states need a representation; the "evicting" label from the plan is a
/// transient one-tick condition handled by the engine via `recordTermination`.
enum TrackedState: Equatable {
    /// Bundle has been windowless since `since`. `timeout` is captured so a
    /// later config change with a different timeout re-anchors `since`.
    case tracked(since: SuspendingClock.Instant, timeout: Duration)

    /// Bundle was recently evicted and is in post-termination cooldown.
    /// No re-tracking until `now >= until`.
    case cooldown(until: SuspendingClock.Instant)
}
