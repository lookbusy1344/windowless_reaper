import Foundation

/// Pure value type that holds the per-bundle state machine and decides what
/// the engine should do each tick. Has no I/O — given a clock instant, the
/// current snapshots, and the active config, it returns a list of `Decision`s
/// and mutates its internal state to match.
///
/// The engine is responsible for performing the side effects (calling the
/// terminator on `.evict` decisions) and then feeding the outcomes back via
/// `recordTermination(...)`.
struct StateTracker: Equatable {
    private(set) var states: [BundleID: TrackedState]

    init(states: [BundleID: TrackedState] = [:]) {
        self.states = states
    }

    /// Serialise to a `Codable` snapshot anchored at `now`. Each entry
    /// stores a *duration* (elapsed since track, or remaining cooldown)
    /// rather than a `SuspendingClock.Instant`, because the clock has no
    /// durable representation — see power_man_best_practices.md §2.18. On
    /// reload, durations are re-anchored against the new `now`, which is
    /// correct because `SuspendingClock` paused across sleep: the elapsed
    /// values represent user-visible time and remain meaningful.
    func snapshot(now: SuspendingClock.Instant) -> TrackerSnapshot {
        let entries = states
            .sorted(by: { $0.key.value < $1.key.value })
            .map { bundleID, state -> TrackerSnapshot.Entry in
                switch state {
                case .tracked(let since, let timeout):
                    let elapsed = now - since
                    return TrackerSnapshot.Entry(
                        bundleID: bundleID.value,
                        kind: .tracked,
                        elapsedSeconds: max(0, Int(elapsed.components.seconds)),
                        timeoutSeconds: timeout.seconds
                    )
                case .cooldown(let until):
                    let remaining = until - now
                    return TrackerSnapshot.Entry(
                        bundleID: bundleID.value,
                        kind: .cooldown,
                        elapsedSeconds: max(0, Int(remaining.components.seconds)),
                        timeoutSeconds: nil
                    )
                }
            }
        return TrackerSnapshot(entries: entries)
    }

    /// Restore from a snapshot, anchoring durations against `now`. Entries
    /// whose `timeoutSeconds` is missing for a `tracked` row are skipped
    /// (corrupt snapshot — safer than guessing).
    static func restore(_ snapshot: TrackerSnapshot, now: SuspendingClock.Instant) -> StateTracker {
        var states: [BundleID: TrackedState] = [:]
        for entry in snapshot.entries {
            let bundleID = BundleID(entry.bundleID)
            switch entry.kind {
            case .tracked:
                guard let timeoutSecs = entry.timeoutSeconds else { continue }
                let since = now.advanced(by: .seconds(-entry.elapsedSeconds))
                states[bundleID] = .tracked(since: since, timeout: Duration(seconds: timeoutSecs))
            case .cooldown:
                let until = now.advanced(by: .seconds(entry.elapsedSeconds))
                states[bundleID] = .cooldown(until: until)
            }
        }
        return StateTracker(states: states)
    }

    /// Apply one tick. Returns the per-bundle decisions for this tick.
    ///
    /// Ordering of decisions is sorted by bundle-ID string so test assertions
    /// remain deterministic; the engine does not depend on order.
    mutating func tick(
        now: SuspendingClock.Instant,
        snapshots: [AppSnapshot],
        config: Config
    ) -> [Decision] {
        // Drop persistent state for any bundle whose rule is no longer present
        // (config hot-reload removed it). This must happen before per-bundle
        // dispatch so a removed rule never produces a decision.
        for bundleID in states.keys where config.rules[bundleID] == nil {
            states.removeValue(forKey: bundleID)
        }

        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.bundleID, $0) })
        let relevantIDs = Set(config.rules.keys).union(states.keys)

        var decisions: [Decision] = []
        for bundleID in relevantIDs.sorted(by: { $0.value < $1.value }) {
            guard let rule = config.rules[bundleID] else { continue }
            if let decision = step(now: now, bundleID: bundleID, rule: rule, snapshot: snapshotByID[bundleID]) {
                decisions.append(decision)
            }
        }
        return decisions
    }

    /// Stage a cooldown for `bundleID` *before* the terminator is called.
    /// Per power_man_best_practices.md §4.16, the cooldown must be durable
    /// before the kill: a crash between `terminate()` and a post-hoc
    /// cooldown write could otherwise let the next restart re-terminate
    /// the same bundle. The engine checkpoints after this returns and
    /// before invoking the terminator.
    ///
    /// Returns true iff a cooldown was staged (false means the rule is
    /// gone or has `timeout = "none"` — the caller should still call
    /// `terminate()` but there is nothing to roll back on veto).
    @discardableResult
    mutating func beginEviction(bundleID: BundleID, now: SuspendingClock.Instant, config: Config) -> Bool {
        guard let rule = config.rules[bundleID], let ruleTimeout = rule.timeout else {
            states.removeValue(forKey: bundleID)
            return false
        }
        let cooldown = (rule.cooldown ?? config.settings.defaultCooldown).resolved(for: ruleTimeout)
        states[bundleID] = .cooldown(until: now.advanced(by: .seconds(cooldown.seconds)))
        return true
    }

    /// Roll back a staged cooldown when the terminator vetoed the kill
    /// (unsaved-work dialog, sandbox refusal, etc.). Resets `since` to
    /// `now` so the timer starts over; the next tick will typically see
    /// the dialog window and untrack the bundle. The safe-direction
    /// crash window: a crash between `beginEviction` and `vetoEviction`
    /// leaves a too-long cooldown, never a duplicate kill.
    mutating func vetoEviction(bundleID: BundleID, now: SuspendingClock.Instant, config: Config) {
        guard let rule = config.rules[bundleID], let ruleTimeout = rule.timeout else {
            states.removeValue(forKey: bundleID)
            return
        }
        states[bundleID] = .tracked(since: now, timeout: ruleTimeout)
    }

    /// Convenience wrapper preserving the pre-§4.16 API for existing
    /// tests: stage-then-veto when accepted/not, no checkpoint. The
    /// production engine path now writes the checkpoint between the two
    /// halves; this entry point is no longer called by the engine.
    mutating func recordTermination(
        bundleID: BundleID,
        allAccepted: Bool,
        now: SuspendingClock.Instant,
        config: Config
    ) {
        if allAccepted {
            _ = beginEviction(bundleID: bundleID, now: now, config: config)
        } else {
            vetoEviction(bundleID: bundleID, now: now, config: config)
        }
    }

    // MARK: - Per-bundle dispatch

    private mutating func step(
        now: SuspendingClock.Instant,
        bundleID: BundleID,
        rule: Rule,
        snapshot: AppSnapshot?
    ) -> Decision? {
        // `timeout = "none"` means the bundle is allowlisted but never reaped.
        // Drop any leftover persistent state (e.g. timeout was just flipped to
        // none via hot-reload) and report ignore while the app is running.
        guard let ruleTimeout = rule.timeout else {
            states.removeValue(forKey: bundleID)
            return snapshot == nil ? nil : .ignore(bundleID)
        }

        // Cooldown short-circuits everything else.
        if case .cooldown(let until) = states[bundleID] {
            if now < until {
                return .cooldown(bundleID, until: until)
            }
            // Cooldown expired — fall through as untracked.
            states.removeValue(forKey: bundleID)
        }

        guard let snapshot else {
            // App no longer running. Drop any persistent tracked state.
            states.removeValue(forKey: bundleID)
            return nil
        }

        if snapshot.hasUnknownWindows {
            states.removeValue(forKey: bundleID)
            return .ignore(bundleID)
        }

        if !snapshot.isFullyWindowless {
            // Window present (visible or minimised) — clear any tracking.
            states.removeValue(forKey: bundleID)
            return .ignore(bundleID)
        }

        // Snapshot is fully windowless. Either start or continue tracking.
        if case .tracked(let since, let prevTimeout) = states[bundleID] {
            if prevTimeout != ruleTimeout {
                // Config changed timeout for this bundle — re-anchor.
                states[bundleID] = .tracked(since: now, timeout: ruleTimeout)
                return .track(bundleID, since: now)
            }
            let elapsed = now - since
            if elapsed >= .seconds(ruleTimeout.seconds) {
                return .evict(bundleID, pids: snapshot.pids)
            }
            return .track(bundleID, since: since)
        }

        states[bundleID] = .tracked(since: now, timeout: ruleTimeout)
        return .track(bundleID, since: now)
    }
}

/// Durable representation of `StateTracker` state. Versioned so future
/// schema changes can be detected on load and rejected without a crash.
public struct TrackerSnapshot: Codable, Sendable, Equatable {
    public let version: Int
    public let entries: [Entry]

    public static let currentVersion = 1

    public init(entries: [Entry], version: Int = TrackerSnapshot.currentVersion) {
        self.version = version
        self.entries = entries
    }

    public enum Kind: String, Codable, Sendable {
        case tracked
        case cooldown
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let bundleID: String
        public let kind: Kind
        /// For `.tracked`: seconds windowless. For `.cooldown`: seconds
        /// remaining until cooldown expires.
        public let elapsedSeconds: Int
        /// Only set for `.tracked` entries; the rule timeout at the time
        /// the bundle was first tracked. Lets `restore` reconstruct
        /// `TrackedState.tracked(..., timeout:)` without re-reading config.
        public let timeoutSeconds: Int?

        public init(bundleID: String, kind: Kind, elapsedSeconds: Int, timeoutSeconds: Int?) {
            self.bundleID = bundleID
            self.kind = kind
            self.elapsedSeconds = elapsedSeconds
            self.timeoutSeconds = timeoutSeconds
        }
    }
}
