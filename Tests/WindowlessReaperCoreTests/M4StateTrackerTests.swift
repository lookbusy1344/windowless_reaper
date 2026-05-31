import Foundation
import IOKit
import Synchronization
import Testing
@testable import WindowlessReaperCore

// Intentional white-box coverage: `StateTracker` is the internal state machine
// the plan allows to stay `@testable` because its behavior is the contract.

// MARK: - Helpers

private func bid(_ string: String) -> BundleID {
    BundleID(string)
}

private enum Fixture {
    static let safari = bid("com.apple.Safari")
    static let mail = bid("com.apple.mail")
    static let slack = bid("com.tinyspeck.slackmacgap")

    static func config(
        rules: [BundleID: Rule],
        defaultCooldown: Cooldown = .multiplier(5.0)
    ) -> Config {
        Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: defaultCooldown
            ),
            rules: rules
        )
    }

    static func windowless(_ id: BundleID, pids: [pid_t] = [100]) -> AppSnapshot {
        AppSnapshot(bundleID: id, windowStates: Dictionary(uniqueKeysWithValues: pids.map { ($0, .none) }))
    }

    static func withWindow(_ id: BundleID, pid: pid_t = 100, state: WindowState = .visible) -> AppSnapshot {
        AppSnapshot(bundleID: id, windowStates: [pid: state])
    }

    static func withUnknown(_ id: BundleID, pid: pid_t = 100) -> AppSnapshot {
        AppSnapshot(bundleID: id, windowStates: [pid: .unknown])
    }
}

private extension SuspendingClock.Instant {
    func plus(_ seconds: Int) -> SuspendingClock.Instant {
        advanced(by: .seconds(seconds))
    }
}

// MARK: - Boundary behaviour

@Suite("StateTracker boundary", .timeLimit(.minutes(1)))
struct StateTrackerBoundaryTests {
    @Test("tracksThenEvictsAtBoundary")
    func tracksThenEvictsAtBoundary() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now

        // tick 0: first sighting of windowless safari → start tracking.
        let d0 = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(d0 == [.track(Fixture.safari, since: t0)])

        // tick 1 (just below timeout): still tracking, no evict.
        let d1 = tracker.tick(now: t0.plus(59), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(d1 == [.track(Fixture.safari, since: t0)])

        // tick 2 (at boundary): evict.
        let d2 = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(d2 == [.evict(Fixture.safari, pids: [100])])
    }

    @Test("just-above timeout also evicts")
    func justAboveAlsoEvicts() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        let d = tracker.tick(now: t0.plus(61), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(d == [.evict(Fixture.safari, pids: [100])])
    }
}

// MARK: - Window reappears / app vetoes / app disappears

@Suite("StateTracker resets and drops", .timeLimit(.minutes(1)))
struct StateTrackerResetTests {
    @Test("window reappearing mid-track clears tracking")
    func windowReappearingClears() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        _ = tracker.tick(now: t0.plus(30), snapshots: [Fixture.windowless(Fixture.safari)], config: config)

        // window returns
        let d = tracker.tick(now: t0.plus(40), snapshots: [Fixture.withWindow(Fixture.safari)], config: config)
        #expect(d == [.ignore(Fixture.safari)])
        #expect(tracker.states[Fixture.safari] == nil)
    }

    @Test("terminate veto resets since to now")
    func vetoResetsSince() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        _ = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)

        let tVeto = t0.plus(60)
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: false, now: tVeto, config: config)

        if case .tracked(let since, let timeout) = tracker.states[Fixture.safari] {
            #expect(since == tVeto)
            #expect(timeout.seconds == 60)
        } else {
            Issue.record("Expected tracked state after veto, got \(String(describing: tracker.states[Fixture.safari]))")
        }
    }

    @Test("app disappears mid-track drops state")
    func appDisappearsDrops() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)

        let d = tracker.tick(now: t0.plus(30), snapshots: [], config: config)
        #expect(d.isEmpty)
        #expect(tracker.states[Fixture.safari] == nil)
    }

    @Test("unknown inspection resets tracking without accumulating elapsed time")
    func unknownInspectionResetsTracking() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now

        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        let unknownTick = tracker.tick(now: t0.plus(30), snapshots: [Fixture.withUnknown(Fixture.safari)], config: config)
        #expect(unknownTick == [.ignore(Fixture.safari)])
        #expect(tracker.states[Fixture.safari] == nil)

        let resumed = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(resumed == [.track(Fixture.safari, since: t0.plus(60))])
    }
}

// MARK: - Cooldown

@Suite("StateTracker cooldown", .timeLimit(.minutes(1)))
struct StateTrackerCooldownTests {
    @Test("evictedAppEntersCooldown")
    func evictedAppEntersCooldown() {
        let config = Fixture.config(
            rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))],
            defaultCooldown: .multiplier(5.0)
        )
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        let dEvict = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(dEvict == [.evict(Fixture.safari, pids: [100])])

        let tQuit = t0.plus(61)
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: true, now: tQuit, config: config)

        // 5x of 60s = 300s
        if case .cooldown(let until) = tracker.states[Fixture.safari] {
            #expect(until == tQuit.plus(300))
        } else {
            Issue.record("Expected cooldown state, got \(String(describing: tracker.states[Fixture.safari]))")
        }
    }

    @Test("cooldownPreventsImmediateRetrack")
    func cooldownPreventsImmediateRetrack() {
        let config = Fixture.config(
            rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60), cooldown: .absolute(Duration(seconds: 120)))]
        )
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        _ = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: true, now: t0.plus(60), config: config)

        // App relaunches still-windowless during cooldown.
        let d = tracker.tick(now: t0.plus(90), snapshots: [Fixture.windowless(Fixture.safari, pids: [200])], config: config)
        #expect(d == [.cooldown(Fixture.safari, until: t0.plus(180))])

        // Cooldown still holds at boundary - 1.
        let d2 = tracker.tick(now: t0.plus(179), snapshots: [Fixture.windowless(Fixture.safari, pids: [200])], config: config)
        #expect(d2 == [.cooldown(Fixture.safari, until: t0.plus(180))])
    }

    @Test("cooldown expires returns to untracked and re-tracks")
    func cooldownExpiresAndRetracks() {
        let config = Fixture.config(
            rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60), cooldown: .absolute(Duration(seconds: 120)))]
        )
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        _ = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: true, now: t0.plus(60), config: config)

        // Cooldown ends at t0+180. Now t0+180 → expired, windowless app starts new tracking.
        let d = tracker.tick(now: t0.plus(180), snapshots: [Fixture.windowless(Fixture.safari, pids: [200])], config: config)
        #expect(d == [.track(Fixture.safari, since: t0.plus(180))])
        if case .tracked(let since, _) = tracker.states[Fixture.safari] {
            #expect(since == t0.plus(180))
        } else {
            Issue.record("Expected tracked after cooldown expiry")
        }
    }

    @Test("cooldown survives app disappearing")
    func cooldownSurvivesAppGone() {
        let config = Fixture.config(
            rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60), cooldown: .absolute(Duration(seconds: 120)))]
        )
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        _ = tracker.tick(now: t0.plus(60), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: true, now: t0.plus(60), config: config)

        // App has disappeared; cooldown still counts down.
        let d = tracker.tick(now: t0.plus(90), snapshots: [], config: config)
        #expect(d == [.cooldown(Fixture.safari, until: t0.plus(180))])
    }
}

// MARK: - Multi-PID

@Suite("StateTracker multi-PID", .timeLimit(.minutes(1)))
struct StateTrackerMultiPIDTests {
    @Test("duplicateBundleIDActsOnlyWhenAllPIDsWindowless")
    func duplicateBundleIDActsOnlyWhenAllPIDsWindowless() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now

        // One windowless PID, one windowed PID → not eligible.
        let mixedSnap = AppSnapshot(
            bundleID: Fixture.safari,
            windowStates: [100: .none, 200: .visible]
        )
        let d0 = tracker.tick(now: t0, snapshots: [mixedSnap], config: config)
        #expect(d0 == [.ignore(Fixture.safari)])

        // Now both PIDs go windowless → track.
        let allNone = AppSnapshot(
            bundleID: Fixture.safari,
            windowStates: [100: .none, 200: .none]
        )
        let d1 = tracker.tick(now: t0.plus(10), snapshots: [allNone], config: config)
        #expect(d1 == [.track(Fixture.safari, since: t0.plus(10))])

        // After timeout, evict — both PIDs included.
        let d2 = tracker.tick(now: t0.plus(70), snapshots: [allNone], config: config)
        if case .evict(_, let pids) = d2.first {
            #expect(pids == [100, 200])
        } else {
            Issue.record("Expected evict for both PIDs")
        }
    }
}

// MARK: - Config changes

@Suite("StateTracker config changes", .timeLimit(.minutes(1)))
struct StateTrackerConfigTests {
    @Test("config reload removing a rule untracks")
    func reloadRemovingRuleUntracks() {
        var config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(tracker.states[Fixture.safari] != nil)

        // Rule removed.
        config = Fixture.config(rules: [:])
        let d = tracker.tick(now: t0.plus(10), snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(d.isEmpty)
        #expect(tracker.states[Fixture.safari] == nil)
    }

    @Test("config reload changing timeout re-anchors since")
    func reloadChangingTimeoutReAnchors() {
        var config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        _ = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.safari)], config: config)

        // Same bundle, longer timeout — re-anchor to current tick.
        config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 600))])
        let tNew = t0.plus(30)
        let d = tracker.tick(now: tNew, snapshots: [Fixture.windowless(Fixture.safari)], config: config)
        #expect(d == [.track(Fixture.safari, since: tNew)])
        if case .tracked(let since, let timeout) = tracker.states[Fixture.safari] {
            #expect(since == tNew)
            #expect(timeout.seconds == 600)
        } else {
            Issue.record("Expected re-anchored tracked state")
        }
    }

    @Test("bundle not in config is never tracked")
    func bundleWithoutRuleNeverTracked() {
        let config = Fixture.config(rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        let d = tracker.tick(now: t0, snapshots: [Fixture.windowless(Fixture.mail)], config: config)
        #expect(d.isEmpty)
        #expect(tracker.states[Fixture.mail] == nil)
    }
}

// MARK: - Cooldown resolution

@Suite("Cooldown resolution", .timeLimit(.minutes(1)))
struct CooldownResolutionTests {
    @Test("rule cooldown overrides settings default")
    func ruleCooldownOverridesDefault() {
        let config = Fixture.config(
            rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60), cooldown: .absolute(Duration(seconds: 999)))],
            defaultCooldown: .multiplier(5.0)
        )
        var tracker = StateTracker()
        let t = SuspendingClock.now
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: true, now: t, config: config)
        if case .cooldown(let until) = tracker.states[Fixture.safari] {
            #expect(until == t.plus(999))
        } else {
            Issue.record("Expected cooldown with rule override")
        }
    }

    @Test("default cooldown multiplier applies when rule has no cooldown")
    func defaultMultiplierApplies() {
        let config = Fixture.config(
            rules: [Fixture.safari: Rule(timeout: Duration(seconds: 60))],
            defaultCooldown: .multiplier(3.0)
        )
        var tracker = StateTracker()
        let t = SuspendingClock.now
        tracker.recordTermination(bundleID: Fixture.safari, allAccepted: true, now: t, config: config)
        if case .cooldown(let until) = tracker.states[Fixture.safari] {
            #expect(until == t.plus(180))
        } else {
            Issue.record("Expected cooldown with default multiplier")
        }
    }
}

// MARK: - Multiple bundles in one tick

@Suite("StateTracker multi-bundle", .timeLimit(.minutes(1)))
struct StateTrackerMultiBundleTests {
    @Test("decisions sorted by bundle id and one per bundle")
    func decisionsSorted() {
        let config = Fixture.config(rules: [
            Fixture.safari: Rule(timeout: Duration(seconds: 60)),
            Fixture.mail: Rule(timeout: Duration(seconds: 60)),
            Fixture.slack: Rule(timeout: Duration(seconds: 60)),
        ])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now
        let d = tracker.tick(
            now: t0,
            snapshots: [
                Fixture.windowless(Fixture.slack),
                Fixture.withWindow(Fixture.safari),
                Fixture.windowless(Fixture.mail),
            ],
            config: config
        )
        // Sorted: com.apple.Safari, com.apple.mail, com.tinyspeck.slackmacgap
        #expect(d.count == 3)
        #expect(d[0] == .ignore(Fixture.safari))
        #expect(d[1] == .track(Fixture.mail, since: t0))
        #expect(d[2] == .track(Fixture.slack, since: t0))
    }
}
